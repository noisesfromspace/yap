package goai

import (
	"context"
	"fmt"
	"testing"

	"github.com/zendev-sh/goai/provider"

	"boers.email/yap/agent/llm"
)

func TestImagePartReachesSDK(t *testing.T) {
	url := "data:image/png;base64,iVBORw0KGgo="
	got := toSDKMessage(llm.Message{Role: llm.RoleUser, Content: []llm.Part{
		{Type: llm.PartText, Text: "Look"},
		{Type: llm.PartImage, URL: url},
	}})
	if len(got.Content) != 2 || got.Content[1].Type != provider.PartImage || got.Content[1].URL != url {
		t.Fatalf("image lost by adapter: %+v", got.Content)
	}
}

// fakeModel is a fake GoAI LanguageModel. It records every GenerateParams it
// receives and returns one fixed ordered response (reasoning with a signature,
// text, then a tool call with a thought signature).
type fakeModel struct {
	id        string
	gotParams []provider.GenerateParams
}

func (f *fakeModel) ModelID() string {
	if f.id != "" {
		return f.id
	}
	return "fake"
}

func (f *fakeModel) DoGenerate(ctx context.Context, params provider.GenerateParams) (*provider.GenerateResult, error) {
	return nil, fmt.Errorf("not used")
}

func (f *fakeModel) DoStream(ctx context.Context, params provider.GenerateParams) (*provider.StreamResult, error) {
	f.gotParams = append(f.gotParams, params)
	out := make(chan provider.StreamChunk, 8)
	go func() {
		out <- provider.StreamChunk{Type: provider.ChunkReasoning, Text: "think", Metadata: map[string]any{"signature": "sig-1"}}
		out <- provider.StreamChunk{Type: provider.ChunkText, Text: "hi "}
		out <- provider.StreamChunk{Type: provider.ChunkToolCall, ToolCallID: "c1", ToolName: "t", ToolInput: "{}", Metadata: map[string]any{"thoughtSignature": "ts-1"}}
		out <- provider.StreamChunk{
			Type: provider.ChunkFinish,
			Content: []provider.Part{
				{Type: provider.PartReasoning, Text: "think", ProviderOptions: map[string]any{"signature": "sig-1"}},
				{Type: provider.PartText, Text: "hi "},
				{Type: provider.PartToolCall, ToolCallID: "c1", ToolName: "t", ToolInput: []byte("{}"), ProviderOptions: map[string]any{"thoughtSignature": "ts-1"}},
			},
			FinishReason: provider.FinishToolCalls,
			Usage:        provider.Usage{InputTokens: 3, OutputTokens: 4},
		}
		close(out)
	}()
	return &provider.StreamResult{Stream: out}, nil
}

func TestProviderOptionsAreModelGated(t *testing.T) {
	tests := []struct {
		name, model string
		want        string
	}{
		{name: "openai", model: "gpt-4.1"},
		{name: "openai", model: "gpt-5-chat-latest"},
		{name: "openai", model: "gpt-6-sol", want: "openai"},
		{name: "anthropic", model: "claude-3-5-sonnet"},
		{name: "anthropic", model: "claude-sonnet-4-6", want: "extended"},
		{name: "anthropic", model: "claude-opus-4-8", want: "adaptive"},
		{name: "deepseek", model: "deepseek-chat"},
		{name: "deepseek", model: "deepseek-v4-pro", want: "deepseek"},
	}
	for _, tt := range tests {
		t.Run(tt.name+"/"+tt.model, func(t *testing.T) {
			m := &modelImpl{model: &fakeModel{id: tt.model}, name: tt.name}
			opts := m.providerOptions("")
			switch tt.want {
			case "":
				if opts != nil {
					t.Fatalf("unexpected options: %#v", opts)
				}
			case "openai":
				if opts["reasoning_summary"] != "auto" {
					t.Fatalf("options: %#v", opts)
				}
			case "extended", "adaptive", "deepseek":
				thinking, _ := opts["thinking"].(map[string]any)
				wantType := map[string]string{"extended": "enabled", "adaptive": "adaptive", "deepseek": "enabled"}[tt.want]
				if thinking["type"] != wantType {
					t.Fatalf("options: %#v", opts)
				}
			}
		})
	}
}

func TestProviderOptionsReasoningLevel(t *testing.T) {
	// OpenAI reasoning model: level -> reasoning_effort, summary preserved.
	oai := (&modelImpl{model: &fakeModel{id: "gpt-6-sol"}, name: "openai"}).providerOptions("high")
	if oai["reasoning_effort"] != "high" || oai["reasoning_summary"] != "auto" {
		t.Fatalf("openai: %#v", oai)
	}
	// Anthropic adaptive: level -> effort, adaptive thinking preserved.
	ad := (&modelImpl{model: &fakeModel{id: "claude-opus-4-8"}, name: "anthropic"}).providerOptions("high")
	if ad["effort"] != "high" {
		t.Fatalf("anthropic adaptive effort: %#v", ad)
	}
	if th, _ := ad["thinking"].(map[string]any); th["type"] != "adaptive" {
		t.Fatalf("anthropic adaptive thinking lost: %#v", ad)
	}
	// Anthropic extended: level scales the thinking budget.
	ex := (&modelImpl{model: &fakeModel{id: "claude-sonnet-4-6"}, name: "anthropic"}).providerOptions("high")
	if th, _ := ex["thinking"].(map[string]any); th["budgetTokens"] != 16384 {
		t.Fatalf("anthropic extended budget: %#v", ex)
	}
	// Google: level -> thinkingLevel.
	gl := (&modelImpl{model: &fakeModel{id: "gemini-3-pro"}, name: "google"}).providerOptions("low")
	if tc, _ := gl["thinkingConfig"].(map[string]any); tc["thinkingLevel"] != "low" {
		t.Fatalf("google: %#v", gl)
	}
	// DeepSeek: level is a no-op; thinking stays enabled.
	ds := (&modelImpl{model: &fakeModel{id: "deepseek-v4-pro"}, name: "deepseek"}).providerOptions("high")
	if th, _ := ds["thinking"].(map[string]any); th["type"] != "enabled" {
		t.Fatalf("deepseek: %#v", ds)
	}
	// OpenAI-compatible: level forwarded verbatim.
	cp := (&modelImpl{model: &fakeModel{id: "kimi-k3"}, name: "compat"}).providerOptions("medium")
	if cp["reasoning_effort"] != "medium" {
		t.Fatalf("compat: %#v", cp)
	}
	// Empty level -> no effort knob on a compat provider.
	if none := (&modelImpl{model: &fakeModel{id: "kimi-k3"}, name: "compat"}).providerOptions(""); none != nil {
		t.Fatalf("compat empty level: %#v", none)
	}
}

func TestDoStreamForwardsReasoning(t *testing.T) {
	fake := &fakeModel{}
	m := &modelImpl{model: fake, name: "compat"}
	msgs := []llm.Message{{Role: llm.RoleUser, Content: []llm.Part{{Type: llm.PartText, Text: "go"}}}}
	s, err := m.DoStream(context.Background(), llm.Params{Messages: msgs, ReasoningLevel: "high"})
	if err != nil {
		t.Fatal(err)
	}
	for range s.Events {
	}
	if r := s.Result(); r.Err != nil {
		t.Fatal(r.Err)
	}
	if len(fake.gotParams) != 1 {
		t.Fatalf("expected 1 generation call, got %d", len(fake.gotParams))
	}
	got := fake.gotParams[0]
	if got.ProviderOptions["reasoning_effort"] != "high" {
		t.Fatalf("reasoning effort not forwarded: %#v", got.ProviderOptions)
	}
}

// TestDoStreamPreservesOrderedPartsAcrossToolResult proves the adapter keeps
// GoAI's exact ordered assistant parts (and their provider metadata) intact
// from the first response through a Yap tool result into the second request.
func TestDoStreamPreservesOrderedPartsAcrossToolResult(t *testing.T) {
	fake := &fakeModel{}
	m := &modelImpl{model: fake, name: "compat"}
	tools := []llm.Tool{{Name: "t", InputSchema: []byte(`{"type":"object"}`)}}

	// First generation: a user message only.
	msgs := []llm.Message{{Role: llm.RoleUser, Content: []llm.Part{{Type: llm.PartText, Text: "go"}}}}
	s1, err := m.DoStream(context.Background(), llm.Params{Messages: msgs, Tools: tools})
	if err != nil {
		t.Fatal(err)
	}
	var reasoningText, textText string
	for ev := range s1.Events {
		switch ev.Type {
		case llm.EventReasoning:
			reasoningText += ev.Text
		case llm.EventText:
			textText += ev.Text
		}
	}
	r1 := s1.Result()
	if r1.Err != nil {
		t.Fatal(r1.Err)
	}
	if reasoningText != "think" || textText != "hi " {
		t.Fatalf("streamed text wrong: reasoning=%q text=%q", reasoningText, textText)
	}
	if len(r1.ResponseMessages) != 1 {
		t.Fatalf("expected 1 assistant response message, got %d", len(r1.ResponseMessages))
	}
	parts := r1.ResponseMessages[0].Content
	if len(parts) != 3 || parts[0].Type != llm.PartReasoning || parts[1].Type != llm.PartText || parts[2].Type != llm.PartToolCall {
		t.Fatalf("ordered parts wrong: %+v", parts)
	}
	if parts[0].ProviderOptions["signature"] != "sig-1" {
		t.Fatalf("reasoning signature lost: %+v", parts[0].ProviderOptions)
	}
	if parts[2].ProviderOptions["thoughtSignature"] != "ts-1" {
		t.Fatalf("thought signature lost: %+v", parts[2].ProviderOptions)
	}

	// Second generation: append the exact assistant message + a native
	// tool-result message, as the agent loop does.
	history := append(append([]llm.Message{}, msgs...), r1.ResponseMessages...)
	history = append(history, llm.Message{
		Role:    llm.RoleTool,
		Content: []llm.Part{{Type: llm.PartToolResult, ToolCallID: "c1", ToolName: "t", ToolOutput: "result"}},
	})
	s2, err := m.DoStream(context.Background(), llm.Params{Messages: history, Tools: tools})
	if err != nil {
		t.Fatal(err)
	}
	for range s2.Events {
	}
	if r2 := s2.Result(); r2.Err != nil {
		t.Fatal(r2.Err)
	}

	// The fake saw the exact parts unchanged on the second generation.
	if len(fake.gotParams) != 2 {
		t.Fatalf("expected 2 generation calls, got %d", len(fake.gotParams))
	}
	got := fake.gotParams[1].Messages
	if len(got) != 3 {
		t.Fatalf("expected [user, assistant, tool] on second generation, got %d messages", len(got))
	}
	asst := got[1]
	if asst.Role != provider.RoleAssistant || len(asst.Content) != 3 {
		t.Fatalf("assistant message wrong: %+v", asst)
	}
	if asst.Content[0].Type != provider.PartReasoning || asst.Content[0].ProviderOptions["signature"] != "sig-1" {
		t.Fatalf("reasoning part/options not preserved: %+v", asst.Content[0])
	}
	if asst.Content[1].Type != provider.PartText || asst.Content[1].Text != "hi " {
		t.Fatalf("text part not preserved: %+v", asst.Content[1])
	}
	if asst.Content[2].Type != provider.PartToolCall || asst.Content[2].ProviderOptions["thoughtSignature"] != "ts-1" {
		t.Fatalf("tool-call part/options not preserved: %+v", asst.Content[2])
	}
	tool := got[2]
	if tool.Role != provider.RoleTool || len(tool.Content) != 1 || tool.Content[0].ToolCallID != "c1" || tool.Content[0].ToolOutput != "result" {
		t.Fatalf("tool result message wrong: %+v", tool)
	}
}
