package turn

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"sync"
	"testing"
	"time"

	"boers.email/yap/agent/config"
	"boers.email/yap/agent/internal/testutil"
	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/wire"
	sdk "github.com/zendev-sh/goai"
)

// TestKeylessProvider allows a local OpenAI-compatible endpoint without
// inventing a dummy API key environment variable.
func TestKeylessProvider(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfigJSON(t, fmt.Sprintf(`{"providers":{"local":{"base_url":%q}}}`, srv.URL+"/v1"))
	var out bytes.Buffer
	if err := Send("local", "llama3.2:3b", strings.NewReader(`{"messages":[{"role":"user","content":"hi"}]}`), &out); err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out.String(), "done") {
		t.Fatalf("missing reply: %s", out.String())
	}
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
			testutil.SSE(w, string(chunk))
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"}}]}`)
	}))
	defer chat.Close()
	testutil.WriteConfigJSON(t, fmt.Sprintf(`{"providers":{"mock":{"base_url":%q,"api_key_env":"YAP_TEST_KEY"}}}`, chat.URL+"/v1"))
	t.Setenv("YAP_TEST_KEY", "k")
	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"try a tool"}]}`), &out); err != nil {
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
			testutil.SSE(w,
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
		testutil.SSE(w,
			`{"choices": [{"delta": {"content": "done"}}]}`,
			`{"choices": [], "usage": {"prompt_tokens": 1, "completion_tokens": 1}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out)
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

func TestDeepSeekReasoningContentReplayed(t *testing.T) {
	var requests []map[string]any
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		var body map[string]any
		if err := json.NewDecoder(r.Body).Decode(&body); err != nil {
			t.Fatal(err)
		}
		requests = append(requests, body)
		if len(requests) == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"reasoning_content":"inspect first"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"deepseek": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := Send("deepseek", "deepseek-v4-pro", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if len(requests) != 2 {
		t.Fatalf("requests: %d", len(requests))
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
			testutil.SSE(w,
				`{"choices":[{"delta":{"reasoning_content":"no trailing newline"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
			)
			return
		}
		testutil.SSE(w, `{"choices":[{"delta":{"content":"done"},"finish_reason":"stop"}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, "<!-- yap:thinking\nno trailing newline\n-->\n") {
		t.Fatalf("thinking closer not on its own line:\n%s", s)
	}
}

func TestAssistantDeltasAreEmittedOnce(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"delta-001|"}}]}`,
			`{"choices":[{"delta":{"content":"delta-002|"}}]}`,
			`{"choices":[{"delta":{"content":"delta-003"},"finish_reason":"stop"}]}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":1000}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfigJSON(t, `{"providers": {"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}}}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "gpt-4o", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":800}}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfigJSON(t, `{"providers": {"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}}}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "gpt-4o", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":1000,"completion_tokens":100,"prompt_tokens_details":{"cached_tokens":800}}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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

// cacheOnlyUsageModel reports usage exclusively via cache counters.
type cacheOnlyUsageModel struct{}

func (cacheOnlyUsageModel) DoStream(_ context.Context, _ llm.Params) (*llm.Stream, error) {
	events := make(chan llm.Event, 1)
	events <- llm.Event{Type: llm.EventText, Text: "done"}
	close(events)
	stream := llm.NewStream(events)
	stream.SetResult(llm.Result{Text: "done", Usage: llm.Usage{CacheReadTokens: 3, CacheWriteTokens: 7}})
	return stream, nil
}

type cacheOnlyUsageProvider struct{}

func (cacheOnlyUsageProvider) Model(string) llm.LanguageModel { return cacheOnlyUsageModel{} }

// TestUsageEventsCarryPerStepSplit: a multi-step turn emits one usage event
// per model step, each with its own step_cache_read. That is what separates
// "this step reused the previous turn's history" from "this step reused what
// the turn already sent", instead of hiding both behind a turn average.
func TestUsageEventsCarryPerStepSplit(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
				`{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10}}`,
			)
			return
		}
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"done"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":20,"completion_tokens":5,"prompt_tokens_details":{"cached_tokens":180}}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if got := strings.Count(s, `"type":"usage"`); got != 2 {
		t.Fatalf("usage events = %d, want one per step (2):\n%s", got, s)
	}
	// Step 1 had nothing to reuse; step 2 read the turn's own prefix.
	if !strings.Contains(s, `"step":1,"step_cache_read":0,"step_cache_write":0`) {
		t.Fatalf("step 1 should report no cache read:\n%s", s)
	}
	if !strings.Contains(s, `"step":2,"step_cache_read":180`) {
		t.Fatalf("step 2 should report its own cache read (180):\n%s", s)
	}
	// Cumulative fields stay turn-wide for the winbar chips.
	if !strings.Contains(s, `"cache_read":180`) {
		t.Fatalf("cumulative cache_read missing:\n%s", s)
	}
}

// TestUsageEmitsForCacheOnlyUsage: cache-only usage must still emit a usage
// event, and cache counters must be carried cumulatively into turn_end.
func TestUsageEmitsForCacheOnlyUsage(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return cacheOnlyUsageProvider{}, nil }
	defer func() { providerFactory = oldFactory }()

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if !strings.Contains(s, `"cache_read":3`) || !strings.Contains(s, `"cache_write":7`) {
		t.Fatalf("cache counters missing:\n%s", s)
	}
	if !strings.Contains(s, `"completion":0,"context_prompt":10,"prompt":0,"step":1,"step_cache_read":3,"step_cache_write":7,"step_completion":0,"step_prompt":0,"type":"usage"`) {
		t.Fatalf("cache-only step should still emit usage event:\n%s", s)
	}
	if !strings.Contains(s, `"cache_read":3,"cache_write":7,"completion":0,"context_prompt":10,"model":"m1"`) {
		t.Fatalf("turn_end should include cumulative cache usage:\n%s", s)
	}
}

// TestUsageOmitsCacheWhenProviderReportsNone: when usage has no cache status,
// do not synthesize zero cache counters.
func TestUsageOmitsCacheWhenProviderReportsNone(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"ok"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":4,"completion_tokens":2}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	old := wire.SetFrameWriter(&out)
	defer wire.SetFrameWriter(old)
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := out.String()
	if strings.Contains(s, `"cache_read":0`) || strings.Contains(s, `"cache_write":0`) || strings.Contains(s, `"cache_read"`) || strings.Contains(s, `"cache_write"`) {
		t.Fatalf("cache fields should be absent when provider reports no cache status:\n%s", s)
	}
}

func TestToolCallEventFollowsVisibleHeader(t *testing.T) {
	calls := 0
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if calls == 1 {
			testutil.SSE(w,
				`{"choices":[{"delta":{"content":"before"}}]}`,
				`{"choices":[{"delta":{"tool_calls":[{"index":0,"id":"c1","type":"function","function":{"name":"missing_test_tool","arguments":"{}"}}]}}]}`,
				`{"choices":[{"delta":{},"finish_reason":"tool_calls"}]}`,
				`{"choices":[],"usage":{"prompt_tokens":100,"completion_tokens":10}}`,
			)
			return
		}
		testutil.SSE(w,
			`{"choices":[{"delta":{"content":"after"}}]}`,
			`{"choices":[],"usage":{"prompt_tokens":200,"completion_tokens":20}}`,
		)
	}))
	defer srv.Close()
	testutil.WriteConfig(t, `"mock": {"base_url": "`+srv.URL+`/v1", "api_key_env": "YAP_TEST_KEY"}`)
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
	oldEventOut := wire.SetFrameWriter(writer)
	defer wire.SetFrameWriter(oldEventOut)
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), writer); err != nil {
		t.Fatalf("send: %v", err)
	}
	s := journal.String()
	usage := strings.Index(s, `{"event":{"completion":10,"context_prompt":100,"prompt":100,"step":1,"step_cache_read":0,"step_cache_write":0,"step_completion":10,"step_prompt":100,"type":"usage"},"type":"event"}`)
	header := strings.Index(s, `<!-- yap:tool {"id":"c1"`)
	event := strings.Index(s, `{"event":{"args":"{}","id":"c1","name":"missing_test_tool","type":"tool_call"},"type":"event"}`)
	result := strings.Index(s, "error: unknown tool missing_test_tool")
	after := strings.Index(s, "after")
	finalUsage := strings.Index(s, `"type":"turn_end"`)
	if usage < 0 || header < 0 || event < 0 || result < 0 || after < 0 || finalUsage < 0 ||
		usage >= header || header >= event || event >= result || result >= after || after >= finalUsage ||
		!strings.Contains(s, `"completion":30,"context_prompt":200,"model":"m1","ms":`) ||
		!strings.Contains(s, `"prompt":300,"status":"ok","type":"turn_end"`) {
		t.Fatalf("usage should update after each model step and before tool execution; final event should carry cumulative usage:\n%s", s)
	}
}

type writerFunc func([]byte) (int, error)

func (f writerFunc) Write(p []byte) (int, error) { return f(p) }

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
			testutil.SSE(w,
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
		testutil.SSE(w, `{"choices": [{"delta": {"content": "done"}}]}`)
	}))
	defer srv.Close()
	testutil.WriteConfigJSON(t, fmt.Sprintf(`{"providers": {"mock": {"base_url": "%s/v1", "api_key_env": "YAP_TEST_KEY"}}}`, srv.URL))
	t.Setenv("YAP_TEST_KEY", "k")

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"which model?"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if !found {
		t.Fatal("no tool result reached the model")
	}
}

// retryFakeModel fails with scripted step errors (no streamed output) before
// eventually succeeding with "done".
type retryFakeModel struct {
	calls  int
	errs   []error
	onCall func(int)
}

func (m *retryFakeModel) DoStream(_ context.Context, _ llm.Params) (*llm.Stream, error) {
	m.calls++
	if m.onCall != nil {
		m.onCall(m.calls)
	}
	events := make(chan llm.Event, 1)
	stream := llm.NewStream(events)
	if m.calls <= len(m.errs) {
		close(events)
		stream.SetResult(llm.Result{Err: m.errs[m.calls-1]})
		return stream, nil
	}
	events <- llm.Event{Type: llm.EventText, Text: "done"}
	close(events)
	stream.SetResult(llm.Result{Text: "done", Usage: llm.Usage{PromptTokens: 1, CompletionTokens: 1}})
	return stream, nil
}

type retryFakeProvider struct{ model *retryFakeModel }

func (p retryFakeProvider) Model(string) llm.LanguageModel { return p.model }

// TestRetryTransient503StepError: a transient 503 before any output is emitted
// is retried (with a `retry` event), and the turn succeeds.
func TestRetryTransient503StepError(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &retryFakeModel{errs: []error{&sdk.APIError{StatusCode: 503, IsRetryable: true, Message: "upstream unavailable"}}}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return retryFakeProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	oldDelay := retryBaseDelay
	retryBaseDelay = time.Millisecond
	defer func() { retryBaseDelay = oldDelay }()

	var journal strings.Builder
	oldEventOut := wire.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer wire.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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

// TestRetry429FailsFast: subscription/quota/rate-limit 429s are surfaced
// immediately (no retries, no retry events).
func TestRetry429FailsFast(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &retryFakeModel{errs: []error{&sdk.APIError{StatusCode: 429, IsRetryable: true, Message: "insufficient_quota"}}}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return retryFakeProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	oldDelay := retryBaseDelay
	retryBaseDelay = time.Millisecond
	defer func() { retryBaseDelay = oldDelay }()

	var journal strings.Builder
	oldEventOut := wire.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer wire.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out)
	if err == nil {
		t.Fatal("Send returned nil error for 429")
	}
	if model.calls != 1 {
		t.Fatalf("model called %d times, want 1 (no retry)", model.calls)
	}
	if strings.Contains(journal.String(), `"type":"retry"`) {
		t.Fatalf("unexpected retry event: %s", journal.String())
	}
}

// TestRetry503Bounded: transient 503 retry budget is bounded.
func TestRetry503Bounded(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	errs := make([]error, retryMaxAttempts+1)
	for i := range errs {
		errs[i] = &sdk.APIError{StatusCode: 503, IsRetryable: true, Message: "unavailable"}
	}
	model := &retryFakeModel{errs: errs}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return retryFakeProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	oldDelay := retryBaseDelay
	retryBaseDelay = time.Millisecond
	defer func() { retryBaseDelay = oldDelay }()

	var journal strings.Builder
	oldEventOut := wire.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer wire.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out)
	if err == nil {
		t.Fatal("Send returned nil error for repeated 503")
	}
	if want := 1 + retryMaxAttempts; model.calls != want {
		t.Fatalf("model called %d times, want %d (initial + bounded retries)", model.calls, want)
	}
	if got := strings.Count(journal.String(), `"type":"retry"`); got != retryMaxAttempts {
		t.Fatalf("retry events = %d, want %d: %s", got, retryMaxAttempts, journal.String())
	}
}

// TestRetryCancellationDuringBackoff: cancellation while waiting for a retry
// aborts promptly and does not issue another upstream call.
func TestRetryCancellationDuringBackoff(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	firstCall := make(chan struct{}, 1)
	model := &retryFakeModel{
		errs: []error{&sdk.APIError{StatusCode: 503, IsRetryable: true, Message: "unavailable"}},
		onCall: func(call int) {
			if call == 1 {
				firstCall <- struct{}{}
			}
		},
	}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return retryFakeProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	oldDelay := retryBaseDelay
	retryBaseDelay = 500 * time.Millisecond
	defer func() { retryBaseDelay = oldDelay }()

	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	req := Request{Messages: []Message{{Role: "user", Content: "go"}}}
	var out bytes.Buffer
	errCh := make(chan error, 1)
	go func() {
		errCh <- Run(ctx, "mock", "m1", req, &out, func() Boundary { return Boundary{} }, nil)
	}()
	<-firstCall
	cancel()
	err := <-errCh
	if err != context.Canceled {
		t.Fatalf("Run error = %v, want context canceled", err)
	}
	if model.calls != 1 {
		t.Fatalf("model called %d times, want 1 after cancellation", model.calls)
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
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &textToolCallModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return textToolCallProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	var journal strings.Builder
	oldEventOut := wire.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer wire.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
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

// emptyCompletionModel returns no text, no tool calls and no usage — the
// "empty completion" anomaly the loop must never fail silently.
type emptyCompletionModel struct{}

func (emptyCompletionModel) DoStream(_ context.Context, _ llm.Params) (*llm.Stream, error) {
	events := make(chan llm.Event)
	close(events)
	stream := llm.NewStream(events)
	stream.SetResult(llm.Result{FinishReason: "stop"})
	return stream, nil
}

type emptyCompletionProvider struct{}

func (emptyCompletionProvider) Model(string) llm.LanguageModel { return emptyCompletionModel{} }

// TestEmptyCompletionAuditedAsError: a turn that ends with no answer is
// recorded as an errored turn_end (status "error"), not silently as "ok".
func TestEmptyCompletionAuditedAsError(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return emptyCompletionProvider{}, nil }
	defer func() { providerFactory = oldFactory }()

	var journal strings.Builder
	oldEventOut := wire.SetFrameWriter(writerFunc(func(p []byte) (int, error) {
		journal.Write(p)
		return len(p), nil
	}))
	defer wire.SetFrameWriter(oldEventOut)

	var out bytes.Buffer
	if err := Send("mock", "m1", strings.NewReader(`{"messages":[{"role":"user","content":"go"}]}`), &out); err != nil {
		t.Fatalf("send: %v", err)
	}
	if !strings.Contains(out.String(), "<!-- yap:error") {
		t.Fatalf("missing error marker:\n%s", out.String())
	}
	if !strings.Contains(journal.String(), `"status":"error"`) {
		t.Fatalf("turn_end not marked error: %s", journal.String())
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
