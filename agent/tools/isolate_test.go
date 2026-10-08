package tools

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

// TestMain lets the fetch tool's vpn path re-exec this binary as the
// `fetch-worker` subcommand under the configured vpn prefix. os.Executable()
// points at the test binary during `go test`, so intercepting that argv shape
// here is what makes the fetch round trip testable end-to-end.
func TestMain(m *testing.M) {
	if len(os.Args) >= 3 && os.Args[1] == "fetch-worker" {
		if err := RunFetchWorker(os.Args[2], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, err)
			os.Exit(1)
		}
		os.Exit(0)
	}
	os.Exit(m.Run())
}

// canIsolateNetwork reports whether the exact unshare wrapper the tools use
// works on this host. Tests that need it skip cleanly otherwise (non-Linux,
// no util-linux, or user namespaces disabled).
func canIsolateNetwork(t *testing.T) bool {
	t.Helper()
	if runtime.GOOS != "linux" {
		return false
	}
	if _, err := exec.LookPath("unshare"); err != nil {
		return false
	}
	return exec.Command("unshare", "--user", "--map-root-user", "--net", "true").Run() == nil
}

func TestBashIsolateNetwork(t *testing.T) {
	if !canIsolateNetwork(t) {
		t.Skip("requires linux unshare with user namespaces")
	}
	// Reserve a live loopback port; the isolated command must not reach it.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	host, port, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}

	// Control: the same command without isolation reaches the listener.
	plain := fmt.Sprintf(`{"command":"timeout 5 bash -c 'echo > /dev/tcp/%s/%s' 2>/dev/null && echo REACHED || echo UNREACHED"}`, host, port)
	r, _, err := run(t, "bash", plain)
	if err != nil || !strings.Contains(r, "REACHED") {
		t.Fatalf("control should reach server: %q %v", r, err)
	}

	// Isolated: loopback is cut, so the connect fails.
	isolated := fmt.Sprintf(`{"command":"timeout 5 bash -c 'echo > /dev/tcp/%s/%s' 2>/dev/null && echo REACHED || echo UNREACHED","isolate_network":true}`, host, port)
	r, _, err = run(t, "bash", isolated)
	if err != nil {
		t.Fatalf("isolated bash: %v", err)
	}
	if !strings.Contains(r, "UNREACHED") {
		t.Fatalf("expected UNREACHED under isolation, got %q", r)
	}
}

func TestPythonIsolateNetwork(t *testing.T) {
	if !canIsolateNetwork(t) {
		t.Skip("requires linux unshare with user namespaces")
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {}))
	defer srv.Close()
	host, port, err := net.SplitHostPort(strings.TrimPrefix(srv.URL, "http://"))
	if err != nil {
		t.Fatal(err)
	}

	code := fmt.Sprintf("import socket\ntry:\n    s = socket.create_connection((%q, %s), timeout=3)\n    print(\"REACHED\")\nexcept Exception:\n    print(\"UNREACHED\")", host, port)

	plain := fmt.Sprintf(`{"code":%q}`, code)
	r, _, err := run(t, "python", plain)
	if err != nil || !strings.Contains(r, "REACHED") {
		t.Fatalf("control should reach server: %q %v", r, err)
	}

	isolated := fmt.Sprintf(`{"code":%q,"isolate_network":true}`, code)
	r, _, err = run(t, "python", isolated)
	if err != nil {
		t.Fatalf("isolated python: %v", err)
	}
	if !strings.Contains(r, "UNREACHED") {
		t.Fatalf("expected UNREACHED under isolation, got %q", r)
	}
}

// canUseVPN reports whether the setuid tunnel wrapper and its Mullvad
// namespace are live on this host. Tests that need it skip cleanly otherwise.
func canUseVPN(t *testing.T) bool {
	t.Helper()
	if runtime.GOOS != "linux" {
		return false
	}
	if _, err := os.Stat("/run/wrappers/bin/tunnel"); err != nil {
		return false
	}
	// The wrapper's setns fails when the namespace is not running.
	return exec.Command("/run/wrappers/bin/tunnel", "true").Run() == nil
}

// withVPN sets the vpn prefix for the duration of t and restores it after.
func withVPN(t *testing.T, prefix []string) {
	t.Helper()
	old := vpnPrefix
	SetVPNCommand(prefix)
	t.Cleanup(func() { SetVPNCommand(old) })
}

func TestBashVPN(t *testing.T) {
	if !canUseVPN(t) {
		t.Skip("requires /run/wrappers/bin/tunnel with the Mullvad namespace running")
	}
	withVPN(t, []string{"/run/wrappers/bin/tunnel"})

	// The host has no tun0; the Mullvad namespace's WireGuard interface does.
	r, _, err := run(t, "bash", `{"command":"ip link show tun0","vpn":true}`)
	if err != nil {
		t.Fatalf("vpn bash: %v", err)
	}
	if !strings.Contains(r, "tun0") {
		t.Fatalf("expected tun0 inside the namespace, got %q", r)
	}
}

// fakeVPNWrapper writes an executable that records its argv to a log file
// and then execs the real command, so tests can verify the vpn prefix is
// prepended without a live namespace or network.
func fakeVPNWrapper(t *testing.T) (wrapper, log string) {
	t.Helper()
	dir := t.TempDir()
	wrapper = filepath.Join(dir, "vpn")
	log = filepath.Join(dir, "argv.log")
	script := "#!/bin/sh\nprintf '%s\\n' \"$@\" >> " + log + "\nexec \"$@\"\n"
	if err := os.WriteFile(wrapper, []byte(script), 0o755); err != nil {
		t.Fatal(err)
	}
	return wrapper, log
}

// TestVPNCommandPrefix deterministically checks that each tool prepends the
// configured vpn prefix (and nothing else) to its own command. A fake wrapper
// records its argv and execs the real command, so no VPN namespace or network
// is needed; TestBashVPN covers the real namespace entry end-to-end.
func TestVPNCommandPrefix(t *testing.T) {
	wrapper, log := fakeVPNWrapper(t)
	withVPN(t, []string{wrapper})
	readLog := func() []string {
		data, err := os.ReadFile(log)
		if err != nil {
			t.Fatalf("read wrapper log: %v", err)
		}
		return strings.Fields(string(data))
	}

	// bash: the prefix runs `bash -c <cmd>`.
	if r, _, err := run(t, "bash", `{"command":"echo vpnok","vpn":true}`); err != nil || !strings.Contains(r, "vpnok") {
		t.Fatalf("vpn bash: %q %v", r, err)
	}
	if argv := readLog(); len(argv) < 1 || argv[0] != "bash" {
		t.Fatalf("bash prefix argv wrong: %q", argv)
	}

	// curl: the prefix runs `curl <args>` against a local server.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		_, _ = w.Write([]byte("curlvpnok"))
	}))
	defer srv.Close()
	if err := os.Remove(log); err != nil {
		t.Fatal(err)
	}
	if r, _, err := run(t, "curl", `{"url":"`+srv.URL+`/","vpn":true}`); err != nil || !strings.Contains(r, "curlvpnok") {
		t.Fatalf("vpn curl: %q %v", r, err)
	}
	if argv := readLog(); len(argv) < 1 || argv[0] != "curl" {
		t.Fatalf("curl prefix argv wrong: %q", argv)
	}

	// fetch: the prefix runs `<test binary> fetch-worker <url>`.
	if err := os.Remove(log); err != nil {
		t.Fatal(err)
	}
	if r, _, err := run(t, "fetch", `{"url":"`+srv.URL+`/data","vpn":true}`); err != nil || !strings.Contains(r, "curlvpnok") {
		t.Fatalf("vpn fetch: %q %v", r, err)
	}
	if argv := readLog(); len(argv) < 2 || argv[1] != "fetch-worker" {
		t.Fatalf("fetch prefix argv wrong: %q", argv)
	}
}

func TestVPNExclusiveWithIsolateNetwork(t *testing.T) {
	withVPN(t, []string{"/run/wrappers/bin/tunnel"})
	if _, _, err := run(t, "bash", `{"command":"true","vpn":true,"isolate_network":true}`); err == nil || !strings.Contains(err.Error(), "mutually exclusive") {
		t.Fatalf("bash: expected mutual-exclusion error, got %v", err)
	}
}

func TestVPNRequiresConfig(t *testing.T) {
	old := vpnPrefix
	SetVPNCommand(nil)
	t.Cleanup(func() { SetVPNCommand(old) })

	for _, tc := range []struct{ tool, args string }{
		{"bash", `{"command":"true","vpn":true}`},
		{"curl", `{"url":"https://example.com/","vpn":true}`},
		{"fetch", `{"url":"https://example.com/","vpn":true}`},
	} {
		if _, _, err := run(t, tc.tool, tc.args); err == nil || !strings.Contains(err.Error(), "vpn.command") {
			t.Fatalf("%s: expected vpn config error, got %v", tc.tool, err)
		}
	}
}

func TestFetchWorker(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(`{"a":1}`))
	}))
	defer srv.Close()

	var buf bytes.Buffer
	if err := RunFetchWorker(srv.URL+"/data", &buf); err != nil {
		t.Fatalf("worker: %v", err)
	}
	status, statusText, contentType, finalURL, body, err := parseFetchWorker(buf.Bytes(), srv.URL)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if status != http.StatusOK || statusText != "200 OK" || contentType != "application/json" || finalURL == nil {
		t.Fatalf("worker output wrong: %d %q %q %v", status, statusText, contentType, finalURL)
	}
	got, _, err := fetchProcess(status, statusText, contentType, finalURL, body, false)
	if err != nil || got != `{"a":1}` {
		t.Fatalf("process: %q %v", got, err)
	}
}

func TestParseFetchWorkerError(t *testing.T) {
	_, _, _, _, _, err := parseFetchWorker([]byte(`{"error":"network unreachable"}`), "http://example.com/")
	if err == nil || !strings.Contains(err.Error(), "network unreachable") {
		t.Fatalf("worker error not surfaced: %v", err)
	}
}
