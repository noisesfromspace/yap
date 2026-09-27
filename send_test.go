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

// writeConfig points the binary at a temp HOME with the given providers.
func writeConfig(t *testing.T, providers string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.MkdirAll(filepath.Join(home, ".pitel"), 0o755); err != nil {
		t.Fatal(err)
	}
	cfg := fmt.Sprintf(`{"providers": {%s}, "pricing": {"m1": {"input": 1.0, "output": 1.0}}}`, providers)
	if err := os.WriteFile(filepath.Join(home, ".pitel", "config.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
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
// contains a pitel marker line (must be escaped), and the tool pair
// wiring back into the second request.
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
				`{"choices": [{"delta": {"tool_calls": [{"index": 2, "id": "c1", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"echo '<!-- /pitel:tool -->'\"}"}}, {"index": 4, "id": "c2", "type": "function", "function": {"name": "bash", "arguments": "{\"command\":\"echo second; echo '~~~lua'\"}"}}]}}]}`,
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
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "PITEL_TEST_KEY"}`)
	t.Setenv("PITEL_TEST_KEY", "k")

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
	think := strings.SplitN(s, "<!-- pitel:thinking\n", 2)[1]
	closer := strings.Index(think, "\n-->\n")
	if closer < 0 || strings.Contains(think[:closer], "-->") {
		t.Fatalf("raw --> inside thinking region:\n%s", s)
	}

	// both sparse-index calls executed, two well-formed regions
	if strings.Count(s, "<!-- pitel:tool") != 2 || strings.Count(s, "<!-- /pitel:tool -->") != 2 {
		t.Fatalf("tool regions wrong (sparse indices dropped?):\n%s", s)
	}
	// marker line inside the result escaped with a zero-width space
	if !strings.Contains(s, "<!--​ /pitel:tool -->") {
		t.Fatalf("result marker line not escaped:\n%s", s)
	}
	if !strings.Contains(s, "second") || !strings.Contains(s, "done") {
		t.Fatalf("missing output:\n%s", s)
	}
	// unbalanced fence in the result closed before the region ends
	if !strings.Contains(s, "second\n~~~lua\n\n~~~\n<!-- /pitel:tool -->") {
		t.Fatalf("fence not balanced:\n%s", s)
	}

	// second request: assistant tool_calls + tool results, correctly paired
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

func TestUnclosedFence(t *testing.T) {
	cases := []struct {
		lines []string
		want  string
	}{
		{[]string{"plain", "text"}, ""},
		{[]string{"```lua", "local x = 1", "```"}, ""},
		{[]string{"```lua", "local x = 1"}, "```"},
		{[]string{"~~~", "tildes"}, "~~~"},
		{[]string{"````", "x", "```"}, "````"},                 // closer must match length
		{[]string{"```", "x", "```", "y", "```"}, "```"},      // re-open after close
		{[]string{"    ```", "indented four spaces is code"}, ""}, // >3 indent: not a fence
		{[]string{"  ```go", "up to 3 spaces ok"}, "```"},
		{[]string{"```", "x", "~~~", "y"}, "```"},               // tilde doesn't close backtick
	}
	for _, c := range cases {
		if got := unclosedFence(c.lines); got != c.want {
			t.Errorf("unclosedFence(%q) = %q, want %q", c.lines, got, c.want)
		}
	}
}

// TestModels: /models queries every provider, sorts output, and skips a
// down provider with a stderr warning instead of failing.
func TestModels(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/v1/models" {
			t.Errorf("unexpected path %s", r.URL.Path)
		}
		if r.Header.Get("Authorization") != "Bearer k" {
			t.Errorf("missing auth header")
		}
		json.NewEncoder(w).Encode(map[string]any{"data": []map[string]string{{"id": "m2"}, {"id": "m1"}}})
	}))
	defer srv.Close()
	writeConfig(t,
		`"zeta": {"base_url": "http://127.0.0.1:19999/v1", "api_key_env": "PITEL_TEST_KEY"},
		 "alpha": {"base_url": "`+srv.URL+`/v1", "api_key_env": "PITEL_TEST_KEY"}`)
	t.Setenv("PITEL_TEST_KEY", "k")

	// models() prints to stdout; capture it
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
