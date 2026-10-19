package main

import (
	"bytes"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

// concatTextFrames reconstructs the buffer content from a framed serve
// stream: the concatenation of every `text` frame, in order.
func concatTextFrames(t *testing.T, s string) string {
	t.Helper()
	var out strings.Builder
	for _, line := range strings.Split(s, "\n") {
		if line == "" {
			continue
		}
		var frame struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if err := json.Unmarshal([]byte(line), &frame); err != nil {
			t.Fatalf("bad frame: %v: %q", err, line)
		}
		if frame.Type == "text" {
			out.WriteString(frame.Text)
		}
	}
	return out.String()
}

// TestServeSteerMidTurn: end-to-end through serve() — a `steer` line on
// stdin while a turn runs (during a slow first tool) is injected into the
// buffer mid-turn.
func TestServeSteerMidTurn(t *testing.T) {
	firstCall := make(chan struct{}, 1)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			firstCall <- struct{}{}
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 0.3; echo hi\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	r, w := io.Pipe()
	defer r.Close()
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- serve(r, &out) }()
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}`+"\n")
	<-firstCall // the turn is running: the first LLM call is in flight
	_, _ = io.WriteString(w, `{"type":"steer","text":"also check the tests"}`+"\n")
	_ = w.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("steer blocked serve")
	}
	if calls != 2 {
		t.Fatalf("calls=%d (want 2)", calls)
	}
	if !strings.Contains(concatTextFrames(t, out.String()), "# @user\nalso check the tests") {
		t.Fatalf("steer not injected: %q", out.String())
	}
}

// TestServeModelSwitchMidTurn: end-to-end through serve() — a `model` line
// on stdin while a turn runs (during a slow first tool) switches the model
// at the next boundary, leaving the marker in the buffer.
func TestServeModelSwitchMidTurn(t *testing.T) {
	firstCall := make(chan struct{}, 1)
	var secondModel string
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		if calls == 1 {
			firstCall <- struct{}{}
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 0.3; echo hi\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		secondModel, _ = body["model"].(string)
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"},"other":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	r, w := io.Pipe()
	defer r.Close()
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- serve(r, &out) }()
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}`+"\n")
	<-firstCall // the turn is running: the first LLM call is in flight
	_, _ = io.WriteString(w, `{"type":"model","provider":"other","model":"m2"}`+"\n")
	_ = w.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("model switch blocked serve")
	}
	if calls != 2 {
		t.Fatalf("calls=%d (want 2)", calls)
	}
	if secondModel != "m2" {
		t.Fatalf("second request model = %q, want m2", secondModel)
	}
	if !strings.Contains(concatTextFrames(t, out.String()), `<!-- yap:model {"from":"mock/m1","to":"other/m2"} -->`) {
		t.Fatalf("model marker not injected: %q", out.String())
	}
}
