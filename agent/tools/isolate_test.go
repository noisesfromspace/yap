package tools

import (
	"bytes"
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os"
	"os/exec"
	"runtime"
	"strings"
	"sync/atomic"
	"testing"
)

// TestMain lets the fetch tool's isolate_network path re-exec this binary as
// the `fetch-worker` subcommand under `unshare`. os.Executable() points at
// the test binary during `go test`, so intercepting that argv shape here is
// what makes the isolated-fetch round trip testable end-to-end.
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

func TestCurlIsolateNetwork(t *testing.T) {
	if !canIsolateNetwork(t) {
		t.Skip("requires linux unshare with user namespaces")
	}
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte("reached"))
	}))
	defer srv.Close()

	r, _, err := run(t, "curl", `{"url":"`+srv.URL+`/","isolate_network":true}`)
	if err != nil {
		t.Fatalf("isolated curl: %v", err)
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Fatalf("server reached despite isolation")
	}
	if !strings.Contains(r, "[curl exit code") {
		t.Fatalf("expected curl failure text, got %q", r)
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

func TestFetchIsolateNetwork(t *testing.T) {
	if !canIsolateNetwork(t) {
		t.Skip("requires linux unshare with user namespaces")
	}
	var hits int32
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		atomic.AddInt32(&hits, 1)
		_, _ = w.Write([]byte("reached"))
	}))
	defer srv.Close()

	_, _, err := run(t, "fetch", `{"url":"`+srv.URL+`/","isolate_network":true}`)
	if err == nil {
		t.Fatalf("isolated fetch should fail with no connectivity")
	}
	if atomic.LoadInt32(&hits) != 0 {
		t.Fatalf("server reached despite isolation")
	}
}
