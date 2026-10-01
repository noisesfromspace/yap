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
	"sync"
	"testing"

	"boers.email/yap/agent/utils"
)

// writeConfigJSON writes a full yap.json into a temp config home.
func writeConfigJSON(t *testing.T, cfg string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	xdg := filepath.Join(home, ".config")
	t.Setenv("XDG_CONFIG_HOME", xdg)
	if err := os.MkdirAll(xdg, 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xdg, "yap.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeConfig points the binary at a temp HOME with the given providers and
// an explicit config override for the mock model (m1).
func writeConfig(t *testing.T, providers string) {
	t.Helper()
	writeConfigJSON(t, fmt.Sprintf(`{"providers": {%s}, "pricing": {"m1": {"input": 1.0, "output": 1.0}}}`, providers))
}

func sse(w http.ResponseWriter, chunks ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, c := range chunks {
		fmt.Fprintf(w, "data: %s\n\n", c)
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}

// TestSendToolLoop drives the full agent loop: thinking with an inline
// `-->` split across chunks (must be escaped for renderers), tool calls
// at SPARSE delta indices (must not be dropped), a tool result that
// contains a yap marker line (must be escaped), and the tool pair
// wiring back into the second request as NATIVE tool_calls/tool roles.
func TestSendToolLoop(t *testing.T) {
	var secondRequest map[string]any
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		calls++
		if calls == 1 {
			sse(w,
				`{"choices": [{"delta": {"reasoning_content": "let me think\n--"}}]}`,
				`{"choices": [{"delta": {"reasoning_content": ">\nabout `+"`"+`<!-- x -"}}]}`,
				`{"choices": [{"delta": {"reasoning_content": "->`+"`"+` inline\n"}}]}`,
				`{"choices": [{"delta": {"tool_calls": [{"index": 2, "id": "c1", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"echo '<!-- /yap:tool -->'\"}"}}, {"index": 4, "id": "c2", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"echo second; echo '~~~lua'; echo '<!doctype html><style>body{x:y}</style>'\"}"}}]}}]}`,
				`{"choices": [{"delta": {}, "finish_reason": "tool_calls"}]}`,
				`{"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}`,
			)
			return
		}
		secondRequest = body
		sse(w,
			`{"choices": [{"delta": {"content": "done"}}]}`,
			`{"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}`,
		)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out)
	if err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()

	// thinking: inline --> (split across chunks) escaped, closer intact
	if !strings.Contains(s, "let me think\n-- >\nabout `<!-- x -- >` inline\n") {
		t.Fatalf("thinking escaping wrong:\n%s", s)
	}
	think := strings.SplitN(s, "<!-- yap:thinking\n", 2)[1]
	closer := strings.Index(think, "\n-->\n")
	if closer < 0 || strings.Contains(think[:closer], "-->") {
		t.Fatalf("raw --> inside thinking region:\n%s", s)
	}

	// both sparse-index calls executed, two well-formed regions (count
	// line-anchored: the escaped \<!-- /yap:tool --> result line also
	// contains the closer as a substring)
	if strings.Count(s, "\n<!-- yap:tool") != 2 || strings.Count(s, "\n<!-- /yap:tool -->\n") != 2 {
		t.Fatalf("tool regions wrong (sparse indices dropped?):\n%s", s)
	}
	// R7: exactly one blank line between blocks — never two
	if strings.Contains(s, "\n\n\n") {
		t.Fatalf("double blank line between blocks:\n%s", s)
	}
	// marker line inside the result escaped with a visible backslash
	if !strings.Contains(s, "\\<!-- /yap:tool -->") {
		t.Fatalf("result marker line not escaped:\n%s", s)
	}
	if !strings.Contains(s, "second") || !strings.Contains(s, "done") {
		t.Fatalf("missing output:\n%s", s)
	}
	// content-bearing results are fenced so they render as code, not
	// markdown: the bash output's `~~~lua` must stay literal text inside
	// the fence, with the region closer directly after the fence close
	if !strings.Contains(s, "\n```\nsecond\n~~~lua") {
		t.Fatalf("bash result not fenced:\n%s", s)
	}
	if !strings.Contains(s, "\n```\n<!-- /yap:tool -->") {
		t.Fatalf("fence not balanced:\n%s", s)
	}
	// <style> neutralized with a backslash (raw-HTML results poison
	// treesitter's combined html/css/js injections)
	if unescaped := strings.ReplaceAll(s, "\\<style", ""); strings.Contains(unescaped, "<style") {
		t.Fatalf("style tag not neutralized:\n%s", s)
	}

	// second request: assistant tool_calls + tool results, correctly paired
	// (native tool roles/calls, not flattened transcript text).
	if secondRequest == nil {
		t.Fatal("no second request (agent loop did not continue)")
	}
	msgs := secondRequest["messages"].([]any)
	var tools, assistantCalls []any
	for _, m := range msgs {
		mm := m.(map[string]any)
		if mm["role"] == "tool" {
			tools = append(tools, mm)
		}
		if mm["role"] == "assistant" && mm["tool_calls"] != nil {
			assistantCalls = mm["tool_calls"].([]any)
		}
	}
	if len(tools) != 2 || len(assistantCalls) != 2 {
		t.Fatalf("tool pair wiring: %d results, %d calls", len(tools), len(assistantCalls))
	}
	if tools[0].(map[string]any)["tool_call_id"] != "c1" || tools[1].(map[string]any)["tool_call_id"] != "c2" {
		t.Fatalf("tool_call_id order: %v", tools)
	}
}

func TestDeepSeekReasoningIsEnabledAndReplayed(t *testing.T) {
	var requests []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		requests = append(requests, body)
		if len(requests) == 1 {
			sse(w,
				`{"choices":[{"delta":{"reasoning_content":"inspect first"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"deepseek": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("deepseek", "deepseek-v4-pro", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if len(requests) != 2 {
		t.Fatalf("requests: %d", len(requests))
	}
	for i, req := range requests {
		thinking, _ := req["thinking"].(map[string]any)
		if thinking["type"] != "enabled" {
			t.Fatalf("request %d did not enable thinking: %#v", i+1, req["thinking"])
		}
	}
	messages := requests[1]["messages"].([]any)
	var assistant map[string]any
	for _, raw := range messages {
		m := raw.(map[string]any)
		if m["role"] == "assistant" && m["tool_calls"] != nil {
			assistant = m
		}
	}
	if assistant == nil || assistant["reasoning_content"] != "inspect first" {
		t.Fatalf("reasoning_content not replayed: %#v", assistant)
	}
}

// TestThinkingCloserOnOwnLine: a thinking-only round whose final reasoning
// chunk ends WITHOUT a trailing newline must still close with `-->` on its
// own line. An inline `-->` (e.g. `...text-->`) would not be recognized as
// the comment closer by the fold/parse/repair logic in the harness.
func TestThinkingCloserOnOwnLine(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			sse(w,
				`{"choices":[{"delta":{"reasoning_content":"no trailing newline"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, "<!-- yap:thinking\nno trailing newline\n-->\n") {
		t.Fatalf("thinking closer not on its own line:\n%s", s)
	}
}

func TestAssistantDeltasAreEmittedOnce(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sse(w,
			`{"choices":[{"delta":{"content":"delta-001|"}}]}`,
			`{"choices":[{"delta":{"content":"delta-002|"}}]}`,
			`{"choices":[{"delta":{"content":"delta-003"},"finish_reason":"stop"}]}`,
		)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	got := out.String()
	for _, delta := range []string{"delta-001|", "delta-002|", "delta-003"} {
		if strings.Count(got, delta) != 1 {
			t.Fatalf("%q emitted %d times; stdout=%q", delta, strings.Count(got, delta), got)
		}
	}
	if !strings.Contains(got, "delta-001|delta-002|delta-003") {
		t.Fatalf("assistant delta order changed: %q", got)
	}
}

// TestUsageCostFromCatalog: with no `pricing` block in config, the committed
// catalog supplies both the cost and the context window for a known model.
// The model id is tried verbatim first, so an OpenAI-compatible provider name
// (mock) still resolves "gpt-4o".
func TestUsageCostFromCatalog(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sse(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":1000}}`,
		)
	}))
	defer srv.Close()
	writeConfigJSON(t, `{"providers": {"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}}}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "gpt-4o", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	// gpt-4o is $2.5 in / $10 out per 1M tokens, so 1000/1000 costs $0.0125.
	if !strings.Contains(s, `"cost":0.0125`) {
		t.Fatalf("catalog cost missing or wrong:\n%s", s)
	}
	if !strings.Contains(s, `"context_window":128000`) {
		t.Fatalf("catalog context window missing:\n%s", s)
	}
}

func TestToolCallEventFollowsVisibleHeader(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			sse(w,
				`{"choices":[{"delta":{"content":"before"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"after"}}]}`)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	// Record writes to session stdout and audit-event output in one journal.
	// emitToolHeader must flush before EmitEvent writes tool_call.
	var mu sync.Mutex
	var journal strings.Builder
	writer := writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		journal.Write(p)
		return len(p), nil
	})
	oldEventOut := utils.SetEventWriter(writer)
	defer utils.SetEventWriter(oldEventOut)
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), writer); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := journal.String()
	header := strings.Index(s, `<!-- yap:tool {"id":"c1"`)
	event := strings.Index(s, `yap:event {"args":"{}","id":"c1","name":"missing_test_tool","type":"tool_call"}`)
	result := strings.Index(s, "error: unknown tool missing_test_tool")
	after := strings.Index(s, "after")
	if header < 0 || event < 0 || result < 0 || after < 0 || !(header < event && event < result && result < after) {
		t.Fatalf("tool round ordering must be header -> event -> result -> resumed answer (prose may stream and be repositioned by the harness):\n%s", s)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

func TestUnclosedFence(t *testing.T) {
	cases := []struct {
		lines []string
		want  string
	}{
		{[]string{"plain", "text"}, ""},
		{[]string{"```lua", "local x = 1", "```"}, ""},
		{[]string{"```lua", "local x = 1"}, "```"},
		{[]string{"~~~", "tildes"}, "~~~"},
		{[]string{"````", "x", "```"}, "````"},                    // closer must match length
		{[]string{"```", "x", "```", "y", "```"}, "```"},          // re-open after close
		{[]string{"    ```", "indented four spaces is code"}, ""}, // >3 indent: not a fence
		{[]string{"  ```go", "up to 3 spaces ok"}, "```"},
		{[]string{"```", "x", "~~~", "y"}, "```"}, // tilde doesn't close backtick
	}
	for _, c := range cases {
		if got := unclosedFence(c.lines); got != c.want {
			t.Errorf("unclosedFence(%q) = %q, want %q", c.lines, got, c.want)
		}
	}
}

func TestListModelsNativeShapes(t *testing.T) {
	tests := []struct {
		name, path, response string
		want                 string
		checkAuth            func(*http.Request) bool
	}{
		{
			name: "anthropic", path: "/v1/models", response: `{"data":[{"id":"claude-test"}]}`, want: "claude-test",
			checkAuth: func(r *http.Request) bool {
				return r.Header.Get("x-api-key") == "k" && r.Header.Get("anthropic-version") != ""
			},
		},
		{
			name: "google", path: "/v1beta/models", response: `{"models":[{"name":"models/gemini-test"}]}`, want: "gemini-test",
			checkAuth: func(r *http.Request) bool { return r.Header.Get("x-goog-api-key") == "k" },
		},
	}
	for _, tt := range tests {
		t.Run(tt.name, func(t *testing.T) {
			srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
				if r.URL.Path != tt.path || !tt.checkAuth(r) {
					t.Fatalf("request path=%q headers=%v", r.URL.Path, r.Header)
				}
				fmt.Fprint(w, tt.response)
			}))
			defer srv.Close()
			ids, err := listModels(t.Context(), tt.name, srv.URL, "k")
			if err != nil || len(ids) != 1 || ids[0] != tt.want {
				t.Fatalf("ids=%v err=%v", ids, err)
			}
		})
	}
}

// TestModels: models() queries each configured provider, sorts output, and
// skips a failing provider with a stderr warning.
func TestModels(t *testing.T) {
	good := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			t.Errorf("path: %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer k" {
			t.Errorf("auth header: %s", r.Header.Get("Authorization"))
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"data":[{"id":"m2"},{"id":"m1"}]}`)
	}))
	defer good.Close()
	bad := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		http.Error(w, "nope", http.StatusInternalServerError)
	}))
	defer bad.Close()

	writeConfig(t,
		`"zeta": {"base_url": "`+bad.URL+`/v1", "api_key_env": "YAP_TEST_KEY"},
		 "alpha": {"base_url": "`+good.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	old := os.Stdout
	r, w, _ := os.Pipe()
	os.Stdout = w
	err := models()
	w.Close()
	os.Stdout = old
	var buf bytes.Buffer
	buf.ReadFrom(r)
	if err != nil {
		t.Fatalf("models: %v", err)
	}
	if got := strings.Fields(buf.String()); len(got) != 2 || got[0] != "alpha/m1" || got[1] != "alpha/m2" {
		t.Fatalf("output: %v", got)
	}
}
