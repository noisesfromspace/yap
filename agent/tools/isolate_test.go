package tools

import (
	"fmt"
	"net"
	"net/http"
	"net/http/httptest"
	"os/exec"
	"runtime"
	"strings"
	"testing"
)

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
