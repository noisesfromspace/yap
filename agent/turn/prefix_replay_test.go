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
			ToolCalls: []llm.ToolCall{{ID: "c1", Name: "missing_test_tool", Input: json.RawMessage(`{}`)}},
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

func TestRunCrossTurnPrefixRepresentation(t *testing.T) {
	testutil.WriteConfig(t, `"mock": {"base_url": "http://127.0.0.1:1/v1", "api_key_env": "YAP_TEST_KEY"}`)
	t.Setenv("YAP_TEST_KEY", "k")

	model := &prefixCaptureModel{}
	oldFactory := providerFactory
	providerFactory = func(string, config.Provider) (llm.Provider, error) { return prefixCaptureProvider{model}, nil }
	defer func() { providerFactory = oldFactory }()

	var firstOut bytes.Buffer
	if err := Run(context.Background(), "mock", "m1", Request{Messages: []Message{{Role: "user", Content: "go"}}}, &firstOut, func() Boundary { return Boundary{} }, nil); err != nil {
		t.Fatalf("first turn: %v", err)
	}

	transcript := strings.Join([]string{
		"# @user",
		"go",
		"",
		"# @assistant",
		"I will run a tool.",
		"",
		"<!-- yap:thinking",
		"Need a tool call.",
		"-->",
		"",
		"<!-- yap:tool {\"id\":\"c1\",\"name\":\"missing_test_tool\",\"arguments\":{}} -->",
		"error: unknown tool missing_test_tool",
		"<!-- /yap:tool -->",
		"",
		"The tool failed.",
		"",
		"# @user",
		"Summarize what happened.",
		"",
		"# @assistant",
		"",
	}, "\n")

	var secondOut bytes.Buffer
	if err := Run(context.Background(), "mock", "m1", Request{Transcript: transcript}, &secondOut, func() Boundary { return Boundary{} }, nil); err != nil {
		t.Fatalf("second turn: %v", err)
	}

	if got := len(model.params); got != 3 {
		t.Fatalf("captured %d llm.Params calls, want 3", got)
	}

	firstTurnContinuation := model.params[1].Messages
	var sawNativeAssistantCall, sawNativeToolResult bool
	for _, msg := range firstTurnContinuation {
		if msg.Role == llm.RoleTool {
			for _, part := range msg.Content {
				if part.Type == llm.PartToolResult && part.ToolCallID == "c1" && strings.Contains(part.ToolOutput, "unknown tool missing_test_tool") {
					sawNativeToolResult = true
				}
			}
		}
		if msg.Role == llm.RoleAssistant {
			for _, part := range msg.Content {
				if part.Type == llm.PartToolCall && part.ToolCallID == "c1" && part.ToolName == "missing_test_tool" {
					sawNativeAssistantCall = true
				}
				if part.Type == llm.PartText && strings.Contains(part.Text, "Tool call: missing_test_tool") {
					t.Fatalf("first-turn continuation should stay native, got flattened text: %q", part.Text)
				}
			}
		}
	}
	if !sawNativeAssistantCall || !sawNativeToolResult {
		t.Fatalf("first-turn continuation missing native tool call/result: assistant_call=%v tool_result=%v", sawNativeAssistantCall, sawNativeToolResult)
	}

	secondTurnStart := model.params[2].Messages
	var sawFlattenedAssistant bool
	for _, msg := range secondTurnStart {
		if msg.Role == llm.RoleTool {
			t.Fatalf("second turn should replay transcript as flattened text, found native tool role message: %#v", msg)
		}
		for _, part := range msg.Content {
			if part.Type == llm.PartToolCall || part.Type == llm.PartToolResult {
				t.Fatalf("second turn should not contain native tool parts, got %q", part.Type)
			}
			if msg.Role == llm.RoleAssistant && part.Type == llm.PartText &&
				strings.Contains(part.Text, "Tool call: missing_test_tool") &&
				strings.Contains(part.Text, "Arguments: {}") &&
				strings.Contains(part.Text, "Tool result:") &&
				strings.Contains(part.Text, "error: unknown tool missing_test_tool") {
				sawFlattenedAssistant = true
			}
		}
	}
	if !sawFlattenedAssistant {
		t.Fatalf("second turn missing flattened assistant tool transcript: %#v", secondTurnStart)
	}
}
