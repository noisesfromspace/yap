package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

func TestServeMultipleTurnsAndFailure(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		testutil.SSE(w, `{"choices":[{"delta":{"content":"reply `+fmt.Sprint(calls)+`"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
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
	// The failed turn is also audited: an error event carries the classified
	// code + message.
	if !strings.Contains(s, `"type":"error"`) {
		t.Fatalf("missing error audit event: %q", s)
	}
	// Text arrives in text frames; the failed turn produces none.
	if !strings.Contains(s, "reply 1") || !strings.Contains(s, "reply 2") || strings.Contains(s, "reply 3") {
		t.Fatalf("text frames wrong: %q", s)
	}
}

// TestServeCancelKeepsProcessAlive: a `cancel` notification lets the current
// bash tool finish and stops before the next model step. The persistent serve
// process then accepts a second turn without losing its tool state.
func TestServeCancelKeepsProcessAlive(t *testing.T) {
	firstCall := make(chan struct{}, 1)
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			firstCall <- struct{}{}
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"sleep 0.5; echo completed\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"second turn ok"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
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
	// The cancelled turn leaves a terminal turn_end journal line too.
	if !strings.Contains(s, `"status":"cancelled"`) {
		t.Fatalf("missing cancelled turn_end: %q", s)
	}
	if !strings.Contains(s, "completed") {
		t.Fatalf("graceful stop discarded the tool result: %q", s)
	}
	if !strings.Contains(s, "second turn ok") {
		t.Fatalf("serve did not survive the cancel: %q", s)
	}
	if calls != 2 {
		t.Fatalf("calls=%d want 2", calls)
	}
}

// TestServeCancelMidStream: a `cancel` notification during a model stream
// lets the response finish before reporting cancellation. No partial answer
// or subsequent model step should be produced.
func TestServeCancelMidStream(t *testing.T) {
	started := make(chan struct{}, 1)
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/event-stream")
		fl := http.NewResponseController(w)
		fmt.Fprint(w, "data: {\"choices\":[{\"delta\":{\"content\":\"hello \"}}]}\n\n")
		_ = fl.Flush()
		started <- struct{}{}
		// Stream slowly so the cancel lands mid-stream.
		for i := 0; i < 50; i++ {
			fmt.Fprintf(w, "data: {\"choices\":[{\"delta\":{\"content\":\"%d\"}}]}\n\n", i)
			_ = fl.Flush()
			time.Sleep(20 * time.Millisecond)
		}
		fmt.Fprint(w, "data: [DONE]\n\n")
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
	<-started
	time.Sleep(50 * time.Millisecond) // a prefix has streamed, the stream is live
	_, _ = io.WriteString(w, `{"type":"cancel"}`+"\n")
	_ = w.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancel blocked serve")
	}
	s := out.String()
	if !strings.Contains(s, `"cancelled":true`) {
		t.Fatalf("missing cancelled turn_complete: %q", s)
	}
	if !strings.Contains(s, `49`) {
		t.Fatalf("graceful stop truncated the provider stream: %q", s)
	}
	if strings.Contains(s, `"ok":true`) {
		t.Fatalf("cancelled turn reported ok: %q", s)
	}
}

// lockedBuffer collects serve's frames while the test reads them.
type lockedBuffer struct {
	mu  sync.Mutex
	buf bytes.Buffer
}

func (b *lockedBuffer) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.Write(p)
}

func (b *lockedBuffer) String() string {
	b.mu.Lock()
	defer b.mu.Unlock()
	return b.buf.String()
}

// turnText joins the text frames a turn emitted, which is exactly the markdown
// the frontend appends to the session buffer.
func turnText(frames string) string {
	var sb strings.Builder
	for _, line := range strings.Split(frames, "\n") {
		var f struct {
			Type string `json:"type"`
			Text string `json:"text"`
		}
		if json.Unmarshal([]byte(line), &f) == nil && f.Type == "text" {
			sb.WriteString(f.Text)
		}
	}
	return strings.TrimRight(sb.String(), "\n")
}

// TestServeReplaysNativeHistoryAcrossTurns: the second turn reuses the native
// tool round the first turn already sent (R-prompt-cache) instead of re-sending
// it as flattened assistant text.
func TestServeReplaysNativeHistoryAcrossTurns(t *testing.T) {
	var mu sync.Mutex
	var bodies []string
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		raw, _ := io.ReadAll(r.Body)
		mu.Lock()
		calls++
		n := calls
		bodies = append(bodies, string(raw))
		mu.Unlock()
		switch n {
		case 1:
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"bash","arguments":"{\"command\":\"echo tool-output\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
		case 2:
			testutil.SSE(w, `{"choices":[{"delta":{"content":"first turn done"}}]}`)
		default:
			testutil.SSE(w, `{"choices":[{"delta":{"content":"second turn ok"}}]}`)
		}
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	r, w := io.Pipe()
	defer r.Close()
	out := &lockedBuffer{}
	done := make(chan error, 1)
	go func() { done <- serve(r, out) }()

	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"go"}]}`+"\n")
	deadline := time.Now().Add(10 * time.Second)
	for !strings.Contains(out.String(), `"turn_complete"`) {
		if time.Now().After(deadline) {
			t.Fatalf("first turn never completed: %q", out.String())
		}
		time.Sleep(10 * time.Millisecond)
	}
	// The buffer as the frontend would leave it, then the next prompt.
	block := turnText(out.String())
	transcript := `{"type":"turn","v":1,"provider":"mock","model":"m1","transcript":` + quoteJSON("# @user\ngo\n\n# @assistant\n"+block+"\n\n# @user\nnext\n") + "}\n"
	_, _ = io.WriteString(w, transcript)
	_ = w.Close()

	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(10 * time.Second):
		t.Fatal("second turn blocked serve")
	}
	if !strings.Contains(out.String(), "second turn ok") {
		t.Fatalf("second turn did not run: %q", out.String())
	}
	mu.Lock()
	defer mu.Unlock()
	if len(bodies) != 3 {
		t.Fatalf("upstream calls = %d, want 3", len(bodies))
	}
	if !strings.Contains(bodies[2], `"role":"tool"`) {
		t.Fatalf("follow-up lost the native tool result:\n%s", bodies[2])
	}
	if strings.Contains(bodies[2], "Tool call: bash") {
		t.Fatalf("follow-up re-flattened tool history:\n%s", bodies[2])
	}
}

// quoteJSON encodes s as a JSON string literal.
func quoteJSON(s string) string {
	b, _ := json.Marshal(s)
	return string(b)
}
