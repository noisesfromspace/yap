package main

import (
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

// A serve process must accept the child's reply while its parent tool is
// waiting. A sequential stdin scanner would deadlock here: the reply is read
// from stdin by a separate goroutine while the turn is blocked on the tool.
func TestSubagentReplyWhileTurnRuns(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.SSE(w, `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"subagent","arguments":"{\"agent\":\"scout\",\"task\":\"look\",\"tools\":[\"read\"]}"}}]}}]}`)
			testutil.SSE(w, `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`)
		} else {
			testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
		}
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	r, w := io.Pipe()
	defer r.Close()
	var mu sync.Mutex
	var out strings.Builder
	done := make(chan error, 1)
	go func() { done <- serve(r, &lockedWriter{mu: &mu, b: &out}) }()
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"delegate"}]}`+"\n")
	// The frontend only learns the request id once the `subagent_request`
	// frame is emitted, and the delegation registers its reply channel just
	// before emitting that frame. Reply after the frame, as production does.
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		seen := strings.Contains(out.String(), `"type":"subagent_request"`)
		mu.Unlock()
		if seen {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no subagent_request frame before reply")
		}
		time.Sleep(time.Millisecond)
	}
	_, _ = io.WriteString(w, `{"type":"subagent_result","id":"1","result":"Session: child.md\nfound it"}`+"\n")
	_ = w.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("subagent reply blocked serve")
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 2 || !strings.Contains(out.String(), "Session: child.md") || !strings.Contains(out.String(), "done") {
		t.Fatalf("calls=%d output=%q", calls, out.String())
	}
}

// lockedWriter serializes serve's frame writes with the test's reads, so the
// test can observe the subagent_request frame without a data race.
type lockedWriter struct {
	mu *sync.Mutex
	b  *strings.Builder
}

func (l *lockedWriter) Write(p []byte) (int, error) {
	l.mu.Lock()
	defer l.mu.Unlock()
	return l.b.Write(p)
}

// A graceful cancel must end a turn that is blocked waiting for a child,
// without a second provider call or a process kill.
func TestSubagentCancelUnblocksServe(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		testutil.SSE(w, `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"subagent","arguments":"{\"agent\":\"scout\",\"task\":\"look\",\"tools\":[\"read\"]}"}}]}}]}`)
		testutil.SSE(w, `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	r, w := io.Pipe()
	defer r.Close()
	var mu sync.Mutex
	var out strings.Builder
	done := make(chan error, 1)
	go func() { done <- serve(r, &lockedWriter{mu: &mu, b: &out}) }()
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"delegate"}]}`+"\n")
	// Wait for the delegation to be requested, then cancel instead of replying.
	deadline := time.Now().Add(5 * time.Second)
	for {
		mu.Lock()
		seen := strings.Contains(out.String(), `"type":"subagent_request"`)
		mu.Unlock()
		if seen {
			break
		}
		if time.Now().After(deadline) {
			t.Fatal("no subagent_request frame before cancel")
		}
		time.Sleep(time.Millisecond)
	}
	_, _ = io.WriteString(w, `{"type":"cancel"}`+"\n")
	_ = w.Close()
	select {
	case err := <-done:
		if err != nil {
			t.Fatal(err)
		}
	case <-time.After(5 * time.Second):
		t.Fatal("cancel did not unblock serve")
	}
	mu.Lock()
	defer mu.Unlock()
	if calls != 1 || !strings.Contains(out.String(), `"cancelled":true`) || !strings.Contains(out.String(), "subagent cancelled") {
		t.Fatalf("calls=%d output=%q", calls, out.String())
	}
}
