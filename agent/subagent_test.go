package main

import (
	"bytes"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/internal/testutil"
)

// A serve process must accept the child's reply while its parent tool is
// waiting. A sequential stdin scanner would deadlock here.
func TestSubagentReplyWhileTurnRuns(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.SSE(w, `{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"subagent","arguments":"{\"agent\":\"scout\",\"task\":\"look\"}"}}]}}]}`)
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
	var out bytes.Buffer
	done := make(chan error, 1)
	go func() { done <- serve(r, &out) }()
	_, _ = io.WriteString(w, `{"type":"turn","v":1,"provider":"mock","model":"m1","messages":[{"role":"user","content":"delegate"}]}`+"\n")
	// The first subagent in this serve process uses id 1. The reply arrives
	// after the request line, before the turn has finished.
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
	if calls != 2 || !strings.Contains(out.String(), "Session: child.md") || !strings.Contains(out.String(), "done") {
		t.Fatalf("calls=%d output=%q", calls, out.String())
	}
}
