package main

import (
	"boers.email/yap/agent/llm"
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

func taskCall(id, name string, args any) map[string]any {
	b, _ := json.Marshal(args)
	return map[string]any{"index": 0, "id": id, "type": "function", "function": map[string]string{"name": name, "arguments": string(b)}}
}

func toolRound(w http.ResponseWriter, calls ...map[string]any) {
	for i, c := range calls {
		c["index"] = i
	}
	b, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": calls}, "finish_reason": "tool_calls"}}})
	sse(w, string(b))
}

func TestReadOnlyCallsRunTogether(t *testing.T) {
	var arrivals atomic.Int32
	release := make(chan struct{})
	pages := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if arrivals.Add(1) == 2 {
			close(release)
		}
		select {
		case <-release:
			fmt.Fprint(w, "ok")
		case <-time.After(3 * time.Second):
			fmt.Fprint(w, "timed out")
		}
	}))
	defer pages.Close()
	calls := 0
	chat := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			toolRound(w, taskCall("c1", "fetch", map[string]any{"url": pages.URL + "/one"}), taskCall("c2", "fetch", map[string]any{"url": pages.URL + "/two"}))
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"finished"}}]}`)
	}))
	defer chat.Close()
	writeConfig(t, `"mock":{"base_url":"`+chat.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"fetch both"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	if arrivals.Load() != 2 || strings.Contains(out.String(), "timed out") {
		t.Fatalf("not concurrent: %s", out.String())
	}
}

func TestBackgroundTaskWaitAndAutomaticDrain(t *testing.T) {
	pages := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		time.Sleep(50 * time.Millisecond)
		fmt.Fprint(w, "task result")
	}))
	defer pages.Close()
	for _, automatic := range []bool{false, true} {
		t.Run(fmt.Sprint(automatic), func(t *testing.T) {
			var seen bool
			calls := 0
			chat := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				var body struct {
					Messages []map[string]any `json:"messages"`
				}
				json.NewDecoder(r.Body).Decode(&body)
				calls++
				switch calls {
				case 1:
					toolRound(w, taskCall("start", "start_task", map[string]any{"tool": "fetch", "arguments": fmt.Sprintf(`{"url":%q}`, pages.URL)}))
				case 2:
					if automatic {
						sse(w, `{"choices":[{"delta":{"content":"draft answer"}}]}`)
					} else {
						toolRound(w, taskCall("wait", "wait_tasks", map[string]any{"ids": []string{"task-1"}}))
					}
				default:
					b, _ := json.Marshal(body)
					seen = strings.Contains(string(b), "task result")
					sse(w, `{"choices":[{"delta":{"content":"checked answer"}}]}`)
				}
			}))
			defer chat.Close()
			writeConfig(t, `"mock":{"base_url":"`+chat.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
			t.Setenv("YAP_TEST_KEY", "k")
			var out bytes.Buffer
			if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"work"}]}`), &out); err != nil {
				t.Fatal(err)
			}
			if !seen || calls != 3 || !strings.Contains(out.String(), "task result") {
				t.Fatalf("not delivered: calls=%d seen=%t out=%s", calls, seen, out.String())
			}
		})
	}
}

func TestBackgroundCannotBypassToolAllowlist(t *testing.T) {
	p := &taskPool{tasks: make(map[string]*backgroundTask)}
	allowed := []string{"start_task", "wait_tasks"}
	v := p.call(llm.ToolCall{ID: "c1", Name: "start_task", Input: json.RawMessage(`{"tool":"bash","arguments":"{\"command\":\"touch /tmp/yap-disallowed-test\"}"}`)}, &allowed)
	if !strings.Contains(v.result, "not allowed") || len(p.pending()) != 0 {
		t.Fatal(v.result)
	}
}
