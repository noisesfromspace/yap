package auth

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

type redirectTokenTransport struct{ target *url.URL }

func (r redirectTokenTransport) RoundTrip(req *http.Request) (*http.Response, error) {
	copy := req.Clone(req.Context())
	u := *req.URL
	u.Scheme, u.Host = r.target.Scheme, r.target.Host
	copy.URL = &u
	return http.DefaultTransport.RoundTrip(copy)
}

// Each helper has its own address space, just like separate session backends.
func TestAuthTokenProcess(t *testing.T) {
	if os.Getenv("YAP_AUTH_HELPER") != "1" {
		return
	}
	target, err := url.Parse(os.Getenv("YAP_AUTH_ENDPOINT"))
	if err != nil {
		t.Fatal(err)
	}
	http.DefaultClient = &http.Client{Transport: redirectTokenTransport{target}}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	token, err := Token(ctx, "chatgpt")
	if err != nil {
		t.Fatal(err)
	}
	if token != "new-access" {
		t.Fatalf("unexpected access token")
	}
}

func TestConcurrentProcessRefresh(t *testing.T) {
	dir := t.TempDir()
	t.Setenv("XDG_CONFIG_HOME", dir)
	if err := save(&Creds{ClientID: "test-client", RefreshToken: "old-refresh", Expiry: time.Now().Add(-time.Hour)}); err != nil {
		t.Fatal(err)
	}
	var calls atomic.Int32
	started := make(chan struct{})
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		n := calls.Add(1)
		if err := r.ParseForm(); err != nil {
			t.Error(err)
		}
		if r.Form.Get("refresh_token") != "old-refresh" {
			t.Error("unexpected refresh token")
		}
		if n == 1 {
			close(started)
			// Leave time for a competing process to enter the old unprotected refresh.
			time.Sleep(500 * time.Millisecond)
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"access_token":"new-access","refresh_token":"new-refresh","expires_in":3600}`)
		} else {
			w.WriteHeader(http.StatusBadRequest)
			fmt.Fprint(w, `{"error":"invalid_grant"}`)
		}
	}))
	defer srv.Close()
	helper := func() *exec.Cmd {
		cmd := exec.Command(os.Args[0], "-test.run=^TestAuthTokenProcess$")
		cmd.Env = append(os.Environ(), "YAP_AUTH_HELPER=1", "YAP_AUTH_ENDPOINT="+srv.URL)
		return cmd
	}
	first := helper()
	var firstOut strings.Builder
	first.Stdout, first.Stderr = &firstOut, &firstOut
	if err := first.Start(); err != nil {
		t.Fatal(err)
	}
	defer func() { _ = first.Process.Kill() }()
	select {
	case <-started:
	case <-time.After(5 * time.Second):
		t.Fatal("first helper did not refresh")
	}
	secondOut, secondErr := helper().CombinedOutput()
	firstErr := first.Wait()
	if firstErr != nil {
		t.Errorf("first helper: %v\n%s", firstErr, firstOut.String())
	}
	if secondErr != nil {
		t.Errorf("second helper: %v\n%s", secondErr, secondOut)
	}
	if got := calls.Load(); got != 1 {
		t.Errorf("refresh calls = %d, want 1", got)
	}
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.RefreshToken != "new-refresh" || needsRefresh(c) {
		t.Error("replacement credentials not saved")
	}
}
