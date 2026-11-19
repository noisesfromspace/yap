package turn

import (
	"bytes"
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"boers.email/yap/agent/config"
	"boers.email/yap/agent/internal/testutil"
	"boers.email/yap/agent/llm"
)

// prefixCaptureModel records every llm.Params a turn sends. Step 1 answers with
// a native tool call, later steps with text, so one call to RunCached covers a
// tool round and the final answer.
type prefixCaptureModel struct {
	mu     sync.Mutex
	calls  int
	params []llm.Params
}

func cloneParams(p llm.Params) llm.Params {
	cp := llm.Params{Tools: append([]llm.Tool(nil), p.Tools...)}
	cp.Messages = make([]llm.Message, len(p.Messages))
	for i, m := range p.Messages {
		cp.Messages[i] = llm.Message{Role: m.Role, ProviderOptions: m.ProviderOptions}
		cp.Messages[i].Content = make([]llm.Part, len(m.Content))
		for j, part := range m.Content {
			cp.Messages[i].Content[j] = part
			if part.ToolInput != nil {
				cp.Messages[i].Content[j].ToolInput = append(json.RawMessage(nil), part.ToolInput...)
			}
		}
	}
	return cp
}

func (m *prefixCaptureModel) DoStream(_ context.Context, p llm.Params) (*llm.Stream, error) {
	m.mu.Lock()
	m.params = append(m.params, cloneParams(p))
	call := m.calls
	m.calls++
	m.mu.Unlock()

	events := make(chan llm.Event, 1)
	stream := llm.NewStream(events)
	switch call {
	case 0:
		close(events)
		stream.SetResult(llm.Result{
			ToolCalls:    []llm.ToolCall{{ID: "c1", Name: "missing_test_tool", Input: json.RawMessage(`{}`)}},
			FinishReason: "tool_calls",
			ResponseMessages: []llm.Message{{
				Role: llm.RoleAssistant,
				Content: []llm.Part{{
					Type:       llm.PartToolCall,
					ToolCallID: "c1",
					ToolName:   "missing_test_tool",
					ToolInput:  json.RawMessage(`{}`),
				}},
			}},
		})
	case 1:
		events <- llm.Event{Type: llm.EventText, Text: "first turn done"}
		close(events)
		stream.SetResult(llm.Result{Text: "first turn done"})
	case 2:
		events <- llm.Event{Type: llm.EventText, Text: "second turn done"}
		close(events)
		stream.SetResult(llm.Result{Text: "second turn done"})
	default:
		close(events)
		stream.SetResult(llm.Result{Text: "extra"})
	}
	return stream, nil
}

type prefixCaptureProvider struct{ model *prefixCaptureModel }

func (p prefixCaptureProvider) Model(string) llm.LanguageModel { return p.model }

// followUpParams runs one tool-using turn, then a follow-up turn whose
// transcript is exactly what the first turn left in the buffer, and returns the
// params of the follow-up turn. hist is the session's native history (nil for
// the cold baseline); editBlock rewrites the previous turn's assistant block to
// simulate a user edit.
func followUpParams(t *testing.T, hist *NativeHistory, editBlock func(string) string) llm.Params {
	t.Helper()
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &prefixCaptureModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return prefixCaptureProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()
	noBoundary := func() Boundary { return Boundary{} }

	var firstOut bytes.Buffer
	req := Request{Transcript: "# @user\ngo\n"}
	if err := RunCached(context.Background(), "mock", "m1", req, &firstOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("first turn: %v", err)
	}

	// Exactly the buffer a user would see: the heading the frontend appended,
	// the bytes this turn wrote, then the next prompt.
	// The frontend normalizes the trailing blanks before it appends a heading
	// (R-blank-lines); the model reports no usage here, so the turn itself adds
	// no closing newlines.
	block := strings.TrimRight(firstOut.String(), "\n")
	if editBlock != nil {
		block = editBlock(block)
	}
	transcript := "# @user\ngo\n\n# @assistant\n" + block + "\n\n# @user\nnext\n"

	var secondOut bytes.Buffer
	if err := RunCached(context.Background(), "mock", "m1", Request{Transcript: transcript}, &secondOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("second turn: %v", err)
	}
	if len(model.params) != 3 {
		t.Fatalf("captured %d llm.Params calls, want 3", len(model.params))
	}
	return model.params[2]
}

// assertNativeHistory: the follow-up request still carries the previous turn's
// tool round as native items, and the only new message is the new prompt.
func assertNativeHistory(t *testing.T, msgs []llm.Message) {
	t.Helper()
	var call, result bool
	for _, msg := range msgs {
		if msg.Role == llm.RoleTool {
			for _, part := range msg.Content {
				if part.Type == llm.PartToolResult && part.ToolCallID == "c1" &&
					strings.Contains(part.ToolOutput, "unknown tool missing_test_tool") {
					result = true
				}
			}
		}
		if msg.Role == llm.RoleAssistant {
			for _, part := range msg.Content {
				if part.Type == llm.PartToolCall && part.ToolCallID == "c1" {
					call = true
				}
				if part.Type == llm.PartText && strings.Contains(part.Text, "Tool call: ") {
					t.Fatalf("replay must not flatten tool history: %q", part.Text)
				}
			}
		}
	}
	if !call || !result {
		t.Fatalf("replayed history missing native tool call/result: call=%v result=%v", call, result)
	}
	last := msgs[len(msgs)-1]
	if last.Role != llm.RoleUser || len(last.Content) != 1 || last.Content[0].Text != "next" {
		t.Fatalf("follow-up tail should be the new prompt only: %#v", last)
	}
}

// assertFlattened: the cold path, unchanged: tool history arrives as transcript
// text, because that is what the markdown holds.
func assertFlattened(t *testing.T, msgs []llm.Message) {
	t.Helper()
	for _, msg := range msgs {
		if msg.Role == llm.RoleTool {
			t.Fatalf("cold turn should not send native tool messages: %#v", msg)
		}
		for _, part := range msg.Content {
			if part.Type == llm.PartToolCall || part.Type == llm.PartToolResult {
				t.Fatalf("cold turn should not send native tool parts: %q", part.Type)
			}
		}
	}
	var flattened bool
	for _, msg := range msgs {
		if msg.Role != llm.RoleAssistant {
			continue
		}
		for _, part := range msg.Content {
			if part.Type == llm.PartText &&
				strings.Contains(part.Text, "Tool call: missing_test_tool") &&
				strings.Contains(part.Text, "Tool result:") {
				flattened = true
			}
		}
	}
	if !flattened {
		t.Fatalf("cold turn missing flattened assistant transcript: %#v", msgs)
	}
}

// TestNativeHistoryReplaysAcrossTurns: with a history, turn two extends turn
// one's native array instead of re-flattening the markdown (R-prompt-cache).
func TestNativeHistoryReplaysAcrossTurns(t *testing.T) {
	assertNativeHistory(t, followUpParams(t, &NativeHistory{}, nil).Messages)
}

// TestNativeHistoryColdWithoutCache: no history means today's behaviour, so the
// cache can never be the reason a request changed shape.
func TestNativeHistoryColdWithoutCache(t *testing.T) {
	assertFlattened(t, followUpParams(t, nil, nil).Messages)
}

// TestNativeHistoryColdWhenTranscriptEdited: editing the previous turn's output
// must not send the unedited version the cache holds.
func TestNativeHistoryColdWhenTranscriptEdited(t *testing.T) {
	edited := func(block string) string {
		return strings.Replace(block, "first turn done", "rewritten answer", 1)
	}
	assertFlattened(t, followUpParams(t, &NativeHistory{}, edited).Messages)
}

// TestNativeHistoryColdAfterFailedTurn: a failure invalidates the previous
// successful prefix, even if the frontend restored the original prompt.
func TestNativeHistoryColdAfterFailedTurn(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")
	model := &prefixCaptureModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return prefixCaptureProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()
	hist := &NativeHistory{}
	noBoundary := func() Boundary { return Boundary{} }
	var out bytes.Buffer
	if err := RunCached(context.Background(), "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &out, noBoundary, nil, hist); err != nil {
		t.Fatal(err)
	}
	if len(hist.native) == 0 {
		t.Fatal("successful turn did not populate history")
	}
	// Model construction fails before any output. The next turn must not
	// continue the last good native array across that failed send.
	if err := RunCached(context.Background(), "missing", "m1", Request{Messages: []Message{{Role: "user", Content: "fail"}}}, &out, noBoundary, nil, hist); err == nil {
		t.Fatal("missing provider succeeded")
	}
	if len(hist.native) != 0 {
		t.Fatal("failed turn retained native history")
	}
}

// produced it; a different combo starts cold.
func TestNativeHistoryColdOnModelSwitch(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &prefixCaptureModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return prefixCaptureProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()
	noBoundary := func() Boundary { return Boundary{} }

	hist := &NativeHistory{}
	var firstOut bytes.Buffer
	req := Request{Messages: []Message{{Role: "user", Content: "go"}}}
	if err := RunCached(context.Background(), "mock", "m1", req, &firstOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("first turn: %v", err)
	}
	transcript := "# @user\ngo\n\n# @assistant\n" + strings.TrimRight(firstOut.String(), "\n") + "\n\n# @user\nnext\n"
	var secondOut bytes.Buffer
	if err := RunCached(context.Background(), "mock", "m2", Request{Transcript: transcript}, &secondOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("second turn: %v", err)
	}
	assertFlattened(t, model.params[2].Messages)
}

// thinkingCaptureModel emits reasoning then a native tool call on step 0 —
// so the reasoning item lands in the stored native array, which is the only
// place a cache hit would replay it from — the final answer on step 1, and the
// follow-up answer on step 2. It records every llm.Params so a test can tell
// whether reasoning items were replayed natively.
type thinkingCaptureModel struct {
	mu     sync.Mutex
	calls  int
	params []llm.Params
}

func (m *thinkingCaptureModel) DoStream(_ context.Context, p llm.Params) (*llm.Stream, error) {
	m.mu.Lock()
	m.params = append(m.params, cloneParams(p))
	call := m.calls
	m.calls++
	m.mu.Unlock()

	events := make(chan llm.Event, 2)
	stream := llm.NewStream(events)
	switch call {
	case 0:
		events <- llm.Event{Type: llm.EventReasoning, Text: "hello"}
		close(events)
		stream.SetResult(llm.Result{
			ToolCalls:    []llm.ToolCall{{ID: "c1", Name: "missing_test_tool", Input: json.RawMessage(`{}`)}},
			FinishReason: "tool_calls",
			ResponseMessages: []llm.Message{{
				Role: llm.RoleAssistant,
				Content: []llm.Part{
					{Type: llm.PartReasoning, Text: "hello"},
					{Type: llm.PartToolCall, ToolCallID: "c1", ToolName: "missing_test_tool", ToolInput: json.RawMessage(`{}`)},
				},
			}},
		})
	case 1:
		events <- llm.Event{Type: llm.EventText, Text: "first turn done"}
		close(events)
		stream.SetResult(llm.Result{Text: "first turn done"})
	case 2:
		events <- llm.Event{Type: llm.EventText, Text: "second turn done"}
		close(events)
		stream.SetResult(llm.Result{Text: "second turn done"})
	default:
		close(events)
		stream.SetResult(llm.Result{Text: "extra"})
	}
	return stream, nil
}

type thinkingCaptureProvider struct{ model *thinkingCaptureModel }

func (p thinkingCaptureProvider) Model(string) llm.LanguageModel { return p.model }

// thinkingFollowUp runs one thinking turn, then a follow-up whose transcript
// is exactly what the first turn left in the buffer (optionally edited), and
// returns the follow-up turn's params.
func thinkingFollowUp(t *testing.T, hist *NativeHistory, editBlock func(string) string) llm.Params {
	t.Helper()
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &thinkingCaptureModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return thinkingCaptureProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()
	noBoundary := func() Boundary { return Boundary{} }

	var firstOut bytes.Buffer
	req := Request{Transcript: "# @user\ngo\n"}
	if err := RunCached(context.Background(), "mock", "m1", req, &firstOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("first turn: %v", err)
	}

	block := strings.TrimRight(firstOut.String(), "\n")
	if editBlock != nil {
		block = editBlock(block)
	}
	transcript := "# @user\ngo\n\n# @assistant\n" + block + "\n\n# @user\nnext\n"

	var secondOut bytes.Buffer
	if err := RunCached(context.Background(), "mock", "m1", Request{Transcript: transcript}, &secondOut, noBoundary, nil, hist); err != nil {
		t.Fatalf("second turn: %v", err)
	}
	if len(model.params) != 3 {
		t.Fatalf("captured %d llm.Params calls, want 3", len(model.params))
	}
	return model.params[2]
}

// TestNativeHistoryReplaysThinking: with an unedited transcript the follow-up
// replays the prior turn's native reasoning item.
func TestNativeHistoryReplaysThinking(t *testing.T) {
	msgs := thinkingFollowUp(t, &NativeHistory{}, nil).Messages
	for _, m := range msgs {
		for _, part := range m.Content {
			if part.Type == llm.PartReasoning && part.Text == "hello" {
				return
			}
		}
	}
	t.Fatalf("replayed history missing native reasoning: %#v", msgs)
}

// TestNativeHistoryColdWhenThinkingEdited: editing the thinking block must not
// send the stale reasoning item the cache holds — a thinking edit falls back to
// a cold, flattened start exactly like an edit to prose or a tool result.
func TestNativeHistoryColdWhenThinkingEdited(t *testing.T) {
	edited := func(block string) string {
		return strings.Replace(block, "hello", "goodbye", 1)
	}
	msgs := thinkingFollowUp(t, &NativeHistory{}, edited).Messages
	for _, m := range msgs {
		for _, part := range m.Content {
			if part.Type == llm.PartReasoning {
				t.Fatalf("edited thinking must not replay stale reasoning: %#v", msgs)
			}
		}
	}
}
