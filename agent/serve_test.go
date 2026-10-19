package main

import (
	"bytes"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"
)

func TestServeMultipleTurnsAndFailure(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		sse(w, `{"choices":[{"delta":{"content":"reply `+fmt.Sprint(calls)+`"}}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	input := `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"type":"turn","v":1,"provider":"bad","model":"m1","messages":[{"role":"user","content":"go"}]}` + "\n" +
		`{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"again"}]}` + "\n"
	if err := serve(strings.NewReader(input), &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	if calls != 2 {
		t.Fatalf("calls=%d output=%q", calls, s)
	}
	if strings.Count(s, `"type":"turn_complete"`) != 3 {
		t.Fatalf("expected 3 turn_complete frames: %q", s)
	}
	if strings.Count(s, `"ok":true`) != 2 || strings.Count(s, `"ok":false`) != 1 {
		t.Fatalf("ok/error counts wrong: %q", s)
	}
	// The unknown-provider turn must surface a structured error (-32602
	// invalid params), not a bare string.
	if !strings.Contains(s, `"code":-32602`) || !strings.Contains(s, "unknown provider") {
		t.Fatalf("missing structured error: %q", s)
	}
	// Text arrives in text frames; the failed turn produces none.
	if !strings.Contains(s, "reply 1") || !strings.Contains(s, "reply 2") || strings.Contains(s, "reply 3") {
		t.Fatalf("text frames wrong: %q", s)
	}
}

// TestServeCancelKeepsProcessAlive: a `cancel` notification aborts only the
// in-flight turn (its bash tool's process group is killed and the loop
// unwinds with context.Canceled), and the serve loop then accepts a second
// turn — proving SSH control masters and other tool state would survive.
func TestServeCancelKeepsProcessAlive(t *testing.T) {
	firstCall := make(chan struct{}, 1)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			firstCall <- struct{}{}
			sse(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 30\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"second turn ok"}}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	r, w := io.Pipe()
	defer r.Close()
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- serve(r, &out) }()

	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"sleep"}]}`+"\n")
	<-firstCall // the turn is running (its bash tool is executing)
	_, _ = io.WriteString(w, `{"type":"cancel"}`+"\n")
	// A second turn proves the serve process survived the cancel.
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"again"}]}`+"\n")
	_ = w.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancel or second turn blocked serve")
	}
	s := out.String()
	if !strings.Contains(s, `"cancelled":true`) {
		t.Fatalf("missing cancelled turn_complete: %q", s)
	}
	if !strings.Contains(s, "second turn ok") {
		t.Fatalf("serve did not survive the cancel: %q", s)
	}
	if calls != 2 {
		t.Fatalf("calls=%d want 2", calls)
	}
}
