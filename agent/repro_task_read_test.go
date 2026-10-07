package main

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

// Reproduce: start_task (bash), then a response mixing prose + a native read
// tool call. Confirm the read actually executes and its result reaches the
// model (role:tool) in the following request.
// Reproduce: start_task (bash), then a response whose ONLY output is prose that
// looks like a tool call (flattened transcript form, no native ToolCalls),
// while the background task is still pending. Does the text-tool-call warning
// fire, or is it silently swallowed by the automatic drain?
func TestReproTaskThenTextToolCall(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		switch calls {
		case 1:
			toolRound(w, taskCall("s1", "start_task", map[string]any{
				"tool": "bash",
				"arguments": map[string]any{"command": "sleep 2; echo bg-done"},
			}))
		case 2:
			// prose ONLY, no native tool call: the flattened transcript form
			sse(w, `{"choices":[{"delta":{"content":"Tool call: read\nArguments: {\"path\":\"/tmp/x\"}"}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"stop"}]}`)
		default:
			sse(w, `{"choices":[{"delta":{"content":"final"}}]}`)
		}
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	fmt.Printf("=== OUTPUT (text tool call w/ pending task) ===\n%s\n=== END ===\n", s)
	if strings.Contains(s, "not executed") {
		t.Fatalf("text tool call SHOULD be surfaced, but was suppressed:\n%s", s)
	}
}

func TestReproTaskThenProseRead(t *testing.T) {
	// A real file the read tool can read.
	dir := t.TempDir()
	target := filepath.Join(dir, "bg.go")
	os.WriteFile(target, []byte("package main\n\n// first\n// second\n// third\n"), 0o644)

	var requests []map[string]any
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		requests = append(requests, body)
		calls++
		switch calls {
		case 1:
			toolRound(w, taskCall("s1", "start_task", map[string]any{
				"tool": "bash",
				"arguments": map[string]any{"command": "sleep 2; echo bg-done"},
			}))
		case 2:
			// prose + native read in the SAME assistant message
			prose := `{"choices":[{"delta":{"content":"Now I have a task handle; unrelated work:"}}]}`
			args, _ := json.Marshal(map[string]any{"path": target, "limit": 3})
			tc := fmt.Sprintf(`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"r1","type":"function","function":{"name":"read","arguments":%q}}]}}]}`, string(args))
			sse(w, prose, tc, `{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`)
		default:
			sse(w, `{"choices":[{"delta":{"content":"final answer"}}]}`)
		}
	}))
	defer srv.Close()
	writeConfig(t, `"mock":{"base_url":"`+srv.URL+`/v1","api_key_env":"YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	s := out.String()
	fmt.Printf("=== OUTPUT ===\n%s\n=== END ===\n", s)

	if !strings.Contains(s, "// first") {
		t.Fatalf("read result missing from output:\n%s", s)
	}
	// Find the role:tool message in request #3 (index 2).
	if len(requests) < 3 {
		t.Fatalf("expected >=3 requests, got %d", len(requests))
	}
	var toolResults []map[string]any
	for _, m := range requests[2]["messages"].([]any) {
		mm := m.(map[string]any)
		if mm["role"] == "tool" {
			toolResults = append(toolResults, mm)
		}
	}
	fmt.Printf("=== tool results in request 3: %d ===\n", len(toolResults))
	for _, tr := range toolResults {
		c, _ := tr["content"].(string)
		fmt.Printf("tool_call_id=%v content=%q\n", tr["tool_call_id"], c)
	}
}
