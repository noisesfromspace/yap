package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
	"time"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/utils"
)

// writeConfigJSON writes a full settings.json into a temp config home.
func writeConfigJSON(t *testing.T, cfg string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	xdg := filepath.Join(home, ".config")
	t.Setenv("XDG_CONFIG_HOME", xdg)
	if err := os.MkdirAll(filepath.Join(xdg, "yap"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xdg, "yap", "settings.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
}

// writeConfig points the binary at a temp HOME with the given providers.
func writeConfig(t *testing.T, providers string) {
	t.Helper()
	writeConfigJSON(t, fmt.Sprintf(`{"providers": {%s}}`, providers))
}

func sse(w http.ResponseWriter, chunks ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, c := range chunks {
		fmt.Fprintf(w, "data: %s\n\n", c)
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}

// TestStaticGateBlocksBeforeExecution checks the full dispatch path: a bash
// command matching a static guard rule (sudo) pauses before the command runs.
func TestStaticGateBlocksBeforeExecution(t *testing.T) {
	var toolInput string
	chatCalls := 0
	chat := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		chatCalls++
		if chatCalls == 1 {
			args, _ := json.Marshal(map[string]string{"command": "sudo -n true"})
			toolInput = string(args)
			chunk, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": []any{map[string]any{"index": 0, "id": "call1", "type": "function", "function": map[string]string{"name": "bash", "arguments": toolInput}}}}, "finish_reason": "tool_calls"}}})
			sse(w, string(chunk))
			return
		}
		sse(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer chat.Close()
	writeConfigJSON(t, fmt.Sprintf(`{"providers":{"mock":{"base_url":%q,"api_key_env":"YAP_TEST_KEY"}}}`, chat.URL+"/v1"))
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"try a tool"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "approval requires yap serve") || chatCalls != 2 {
		t.Fatalf("gate did not block and return error to model: calls=%d output=%q", chatCalls, out.String())
	}
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
	// R-blank-lines: exactly one blank line between blocks — never two
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

// TestUsageCostFromCatalog: the committed catalog supplies both the cost and
// the context window for a known model. The model id is tried verbatim first,
// so an OpenAI-compatible provider name (mock) still resolves "gpt-4o".
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
	old := utils.SetFrameWriter(&out)
	defer utils.SetFrameWriter(old)
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

// TestUsageCostIncludesCacheRead: cached input is billed at the cache-read
// rate, not dropped. gpt-4o is $2.5 in / $1.25 cache-read / $10 out per 1M
// tokens, so 200 uncached + 800 cached in and 100 out costs $0.0025.
func TestUsageCostIncludesCacheRead(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sse(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":800}}}`,
		)
	}))
	defer srv.Close()
	writeConfigJSON(t, `{"providers": {"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}}}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := utils.SetFrameWriter(&out)
	defer utils.SetFrameWriter(old)
	if err := send("mock", "gpt-4o", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if !strings.Contains(out.String(), `"cost":0.0025`) {
		t.Fatalf("cache-read cost missing or wrong:\n%s", out.String())
	}
}

// TestContextPromptIncludesCachedTokens: the context-fill gauge's
// context_prompt must reflect the full prompt the model saw (including cached
// input), while prompt keeps its normalized non-cached value so token counts
// and cost are unaffected. OpenAI-compatible providers report cached input via
// prompt_tokens_details.cached_tokens.
func TestContextPromptIncludesCachedTokens(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		sse(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":800}}}`,
		)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := utils.SetFrameWriter(&out)
	defer utils.SetFrameWriter(old)
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, `"context_prompt":1000`) {
		t.Fatalf("context_prompt should carry the full prompt (1000), not the non-cached count:\n%s", s)
	}
	if !strings.Contains(s, `"prompt":200`) {
		t.Fatalf("prompt should stay normalized to non-cached tokens (200):\n%s", s)
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
				`{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10}}`,
			)
			return
		}
		sse(w,
			`{"choices":[{"delta":{"content":"after"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":20}}`,
		)
	}))
	defer srv.Close()
	writeConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	// Record writes to session stdout and audit-event output in one journal.
	// render.EmitToolHeader must flush before EmitEvent writes tool_call.
	var mu sync.Mutex
	var journal strings.Builder
	writer := writerFunc(func(p []byte) (int, error) {
		mu.Lock()
		defer mu.Unlock()
		journal.Write(p)
		return len(p), nil
	})
	oldEventOut := utils.SetFrameWriter(writer)
	defer utils.SetFrameWriter(oldEventOut)
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), writer); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := journal.String()
	usage := strings.Index(s, `{"event":{"completion":10,"context_prompt":100,"prompt":100,"type":"usage"},"type":"event"}`)
	header := strings.Index(s, `<!-- yap:tool {"id":"c1"`)
	event := strings.Index(s, `{"event":{"args":"{}","id":"c1","name":"missing_test_tool","type":"tool_call"},"type":"event"}`)
	result := strings.Index(s, "error: unknown tool missing_test_tool")
	after := strings.Index(s, "after")
	finalUsage := strings.Index(s, `"type":"turn_end"`)
	if usage < 0 || header < 0 || event < 0 || result < 0 || after < 0 || finalUsage < 0 ||
		usage >= header || header >= event || event >= result || result >= after || after >= finalUsage ||
		!strings.Contains(s, `"completion":30,"context_prompt":200,"model":"m1","ms":`) ||
		!strings.Contains(s, `"prompt":300,"type":"turn_end"`) {
		t.Fatalf("usage should update after each model step and before tool execution; final event should carry cumulative usage:\n%s", s)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

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

// TestModelsToolInServe: the serve loop hands main's discovery client to the
// models tool, so a model can list combos without shelling out.
func TestModelsToolInServe(t *testing.T) {
	var found bool
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Method == http.MethodGet && r.URL.Path == "/v1/models" {
			w.Header().Set("Content-Type", "application/json")
			fmt.Fprint(w, `{"data":[{"id":"gpt-5-mini"}]}`)
			return
		}
		calls++
		if calls == 1 {
			sse(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"models","arguments":"{\"filter\":\"gpt-5\"}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		var body map[string]any
		json.NewDecoder(r.Body).Decode(&body)
		for _, m := range body["messages"].([]any) {
			if mm, ok := m.(map[string]any); ok && mm["role"] == "tool" {
				result, _ := mm["content"].(string)
				if !strings.Contains(result, "mock/gpt-5-mini") {
					t.Errorf("models tool result: %q", result)
				}
				if !strings.Contains(result, "in $0.25 · out $2 per 1M tokens") {
					t.Errorf("price hint missing: %q", result)
				}
				found = true
			}
		}
		sse(w, `{"choices": [{"delta": {"content": "done"}}]}`)
	}))
	defer srv.Close()
	writeConfigJSON(t, fmt.Sprintf(`{"providers": {"mock": {"base_url": "%s/v1", "api_key_env": "YAP_TEST_KEY"}}}`, srv.URL))
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"which model?"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if !found {
		t.Fatal("no tool result reached the model")
	}
}

type retryableNetErr struct{}

func (retryableNetErr) Error() string   { return "i/o timeout" }
func (retryableNetErr) Timeout() bool   { return true }
func (retryableNetErr) Temporary() bool { return true }

// retryFakeModel fails its first DoStream with a transient mid-stream error
// (no events, retryable Result.Err) and succeeds on the second call.
type retryFakeModel struct{ calls int }

func (m *retryFakeModel) DoStream(_ context.Context, _ llm.Params) (*llm.Stream, error) {
	m.calls++
	events := make(chan llm.Event, 1)
	stream := llm.NewStream(events)
	if m.calls == 1 {
		close(events)
		stream.SetResult(llm.Result{Err: retryableNetErr{}})
		return stream, nil
	}
	events <- llm.Event{Type: llm.EventText, Text: "done"}
	close(events)
	stream.SetResult(llm.Result{Text: "done", Usage: llm.Usage{PromptTokens: 1, CompletionTokens: 1}})
	return stream, nil
}

type retryFakeProvider struct{ model *retryFakeModel }

func (p retryFakeProvider) Model(string) llm.LanguageModel { return p.model }

// TestRetryTransientStepError: a transient generation error before any output
// is emitted is retried (with a `retry` audit event), and the turn succeeds.
func TestRetryTransientStepError(t *testing.T) {
	writeConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &retryFakeModel{}
	oldFactory := providerFactory
	providerFactory = func(string, Provider) (llm.Provider, error) { return retryFakeProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	oldDelay := retryBaseDelay
	retryBaseDelay = time.Millisecond
	defer func() { retryBaseDelay = oldDelay }()

	var journal strings.Builder
	oldEventOut := utils.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer utils.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if model.calls != 2 {
		t.Fatalf("model called %d times, want 2 (one retry)", model.calls)
	}
	if !strings.Contains(journal.String(), `"type":"retry"`) {
		t.Fatalf("no retry event: %s", journal.String())
	}
	if !strings.Contains(out.String(), "done") {
		t.Fatalf("missing answer: %s", out.String())
	}
}

// textToolCallModel returns one step of prose that looks like a tool call
// but carries no native ToolCalls.
type textToolCallModel struct{ calls int }

func (m *textToolCallModel) DoStream(_ context.Context, _ llm.Params) (*llm.Stream, error) {
	m.calls++
	const text = "Tool call: bash\nArguments: {\"command\":\"echo hi\"}"
	events := make(chan llm.Event, 1)
	events <- llm.Event{Type: llm.EventText, Text: text}
	close(events)
	stream := llm.NewStream(events)
	stream.SetResult(llm.Result{Text: text, Usage: llm.Usage{PromptTokens: 1, CompletionTokens: 1}})
	return stream, nil
}

type textToolCallProvider struct{ model *textToolCallModel }

func (p textToolCallProvider) Model(string) llm.LanguageModel { return p.model }

// TestTextToolCallSurfaced: prose that mimics a tool call (no native call)
// must be surfaced as an error marker + audit event, and must not loop.
func TestTextToolCallSurfaced(t *testing.T) {
	writeConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &textToolCallModel{}
	oldFactory := providerFactory
	providerFactory = func(string, Provider) (llm.Provider, error) { return textToolCallProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	var journal strings.Builder
	oldEventOut := utils.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer utils.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	if err := send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if model.calls != 1 {
		t.Fatalf("model called %d times, want 1 (no tool loop)", model.calls)
	}
	s := out.String()
	if !strings.Contains(s, "<!-- yap:error") || !strings.Contains(s, "not executed") {
		t.Fatalf("missing surface marker:\n%s", s)
	}
	if !strings.Contains(journal.String(), `"type":"tool_text_warning"`) {
		t.Fatalf("missing tool_text_warning event: %s", journal.String())
	}
}

func TestDetectTextToolCall(t *testing.T) {
	cases := []struct {
		text string
		want bool
	}{
		{"Tool call: bash\nArguments: {\"command\":\"x\"}", true},
		{"<invoke name=\"bash\"><parameter name=\"command\">x</parameter></invoke>", true},
		{"plain prose with no call", false},
		{"Tool call: nothing to see here", false},
		// Explaining or quoting the syntax must not trigger detection.
		{"the <invoke> and <parameter> tags are XML", false},
		{"```xml\n<invoke name=\"bash\"><parameter name=\"command\">x</parameter></invoke>\n```", false},
		{"~~~\nTool call: bash\nArguments: {\"command\":\"x\"}\n~~~", false},
	}
	for _, c := range cases {
		if _, got := detectTextToolCall(c.text); got != c.want {
			t.Errorf("detectTextToolCall(%q) = %v, want %v", c.text, got, c.want)
		}
	}
}
