// Package goai adapts the GoAI SDK to Yap's provider surface. It is the only
// package in the repository that imports github.com/zendev-sh/goai (and its
// provider subpackages); the agent loop and tools only see Yap-owned types.
package goai

import (
	"context"
	"fmt"
	"strings"

	sdk "github.com/zendev-sh/goai"
	"github.com/zendev-sh/goai/provider"
	"github.com/zendev-sh/goai/provider/anthropic"
	"github.com/zendev-sh/goai/provider/compat"
	"github.com/zendev-sh/goai/provider/deepseek"
	"github.com/zendev-sh/goai/provider/google"
	"github.com/zendev-sh/goai/provider/openai"

	"boers.email/yap/agent/llm"
)

// NewProvider builds an llm.Provider for the named provider. Native provider
// packages are used for openai/anthropic/google/gemini/deepseek; any other
// name with a base_url falls back to the OpenAI-compatible provider.
func NewProvider(cfg llm.ProviderConfig) (llm.Provider, error) {
	if cfg.Name == "" {
		return nil, fmt.Errorf("provider name is empty")
	}
	switch cfg.Name {
	case "openai", "anthropic", "google", "gemini", "deepseek":
		// native providers carry their own default base URLs
	default:
		if cfg.BaseURL == "" {
			return nil, fmt.Errorf("unsupported provider %q (base_url required)", cfg.Name)
		}
	}
	return &providerImpl{
		name:    cfg.Name,
		baseURL: strings.TrimRight(cfg.BaseURL, "/"),
		apiKey:  cfg.APIKey,
	}, nil
}

type providerImpl struct {
	name    string
	baseURL string
	apiKey  string
}

func (p *providerImpl) Model(modelID string) llm.LanguageModel {
	var m provider.LanguageModel
	switch p.name {
	case "openai":
		var opts []openai.Option
		if p.apiKey != "" {
			opts = append(opts, openai.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, openai.WithBaseURL(p.baseURL))
		}
		m = openai.Chat(modelID, opts...)
	case "anthropic":
		var opts []anthropic.Option
		if p.apiKey != "" {
			opts = append(opts, anthropic.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, anthropic.WithBaseURL(p.baseURL))
		}
		m = anthropic.Chat(modelID, opts...)
	case "google", "gemini":
		var opts []google.Option
		if p.apiKey != "" {
			opts = append(opts, google.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, google.WithBaseURL(p.baseURL))
		}
		m = google.Chat(modelID, opts...)
	case "deepseek":
		var opts []deepseek.Option
		if p.apiKey != "" {
			opts = append(opts, deepseek.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, deepseek.WithBaseURL(p.baseURL))
		}
		m = deepseek.Chat(modelID, opts...)
	default:
		var opts []compat.Option
		if p.apiKey != "" {
			opts = append(opts, compat.WithAPIKey(p.apiKey))
		}
		opts = append(opts, compat.WithBaseURL(p.baseURL))
		m = compat.Chat(modelID, opts...)
	}
	return &modelImpl{model: m, name: p.name}
}

type modelImpl struct {
	model provider.LanguageModel
	name  string
}

// providerOptions returns the per-provider request options that make visible
// reasoning work. They are confined to this adapter; the agent never sees
// them. Google already defaults includeThoughts=true for thinking-capable
// models and DeepSeek streams reasoning_content natively (its provider is
// built with IncludeReasoningContent), so both need no request option.
func (m *modelImpl) providerOptions() map[string]any {
	id := strings.ToLower(m.model.ModelID())
	switch m.name {
	case "openai":
		// Responses API (default): stream a visible reasoning summary and
		// preserve encrypted reasoning items for tool continuation. Do not
		// send reasoning options to non-reasoning models: they reject them.
		if isOpenAIReasoningModel(id) {
			return map[string]any{"reasoning_summary": "auto"}
		}
	case "anthropic":
		// Current adaptive-thinking models can return a visible summary.
		if supportsAnthropicAdaptiveThinking(id) {
			return map[string]any{"thinking": map[string]any{"type": "adaptive", "display": "summarized"}}
		}
		// Older thinking-capable Claude models require a token budget rather
		// than adaptive mode. Leave still older models untouched.
		if supportsAnthropicExtendedThinking(id) {
			return map[string]any{"thinking": map[string]any{"type": "enabled", "budgetTokens": 4096}}
		}
	case "deepseek":
		// DeepSeek V4 and reasoning models require thinking to be enabled;
		// the native adapter also replays their reasoning_content unchanged.
		if strings.Contains(id, "v4") || strings.Contains(id, "reasoner") || strings.Contains(id, "r1") {
			return map[string]any{"thinking": map[string]any{"type": "enabled"}}
		}
	}
	return nil
}

func isOpenAIReasoningModel(id string) bool {
	if (strings.HasPrefix(id, "gpt-5") || strings.HasPrefix(id, "gpt-6")) && !strings.Contains(id, "-chat") {
		return true
	}
	if strings.HasPrefix(id, "codex-") {
		return true
	}
	return len(id) >= 2 && id[0] == 'o' && id[1] >= '0' && id[1] <= '9'
}

func supportsAnthropicAdaptiveThinking(id string) bool {
	return strings.Contains(id, "claude-opus-5") ||
		strings.Contains(id, "claude-sonnet-5") ||
		strings.Contains(id, "claude-fable-5") ||
		strings.Contains(id, "claude-mythos-5") ||
		strings.Contains(id, "claude-opus-4-7") ||
		strings.Contains(id, "claude-opus-4-8")
}

func supportsAnthropicExtendedThinking(id string) bool {
	return strings.Contains(id, "claude-3-7") ||
		strings.Contains(id, "claude-sonnet-4") ||
		strings.Contains(id, "claude-opus-4") ||
		strings.Contains(id, "claude-haiku-4")
}

// DoStream runs ONE generation step (no auto tool loop): the agent executes
// tools and calls DoStream again, so the exact ordered assistant parts and
// provider metadata in Result.ResponseMessages survive into the next request.
func (m *modelImpl) DoStream(ctx context.Context, params llm.Params) (*llm.Stream, error) {
	var system []string
	rest := make([]provider.Message, 0, len(params.Messages))
	for _, msg := range params.Messages {
		if msg.Role == llm.RoleSystem {
			if s := partsText(msg.Content); s != "" {
				system = append(system, s)
			}
			continue
		}
		rest = append(rest, toSDKMessage(msg))
	}
	// A request with only system messages (an empty user prompt) must still
	// generate: keep an empty user turn so GoAI does not reject the call.
	if len(rest) == 0 {
		rest = append(rest, sdk.UserMessage(""))
	}

	opts := []sdk.Option{
		sdk.WithMessages(rest...),
		sdk.WithTools(toSDKTools(params.Tools)...),
		sdk.WithMaxSteps(1),
	}
	if len(system) > 0 {
		opts = append(opts, sdk.WithSystem(strings.Join(system, "\n\n")))
	}
	if po := m.providerOptions(); po != nil {
		opts = append(opts, sdk.WithProviderOptions(po))
	}

	ts, err := sdk.StreamText(ctx, m.model, opts...)
	if err != nil {
		return nil, err
	}

	raw := ts.Stream()
	events := make(chan llm.Event, 64)
	stream := llm.NewStream(events)
	go func() {
		defer close(events)
		for ch := range raw {
			switch ch.Type {
			case provider.ChunkReasoning:
				if ch.Text != "" {
					events <- llm.Event{Type: llm.EventReasoning, Text: ch.Text}
				}
			case provider.ChunkText:
				if ch.Text != "" {
					events <- llm.Event{Type: llm.EventText, Text: ch.Text}
				}
			}
		}
		res := ts.Result()
		var r llm.Result
		if err := ts.Err(); err != nil {
			r.Err = err
		}
		r.Text = res.Text
		r.Reasoning = res.Reasoning
		r.ToolCalls = toLLMToolCalls(res.ToolCalls)
		r.FinishReason = string(res.FinishReason)
		r.Usage = llm.Usage{PromptTokens: res.TotalUsage.InputTokens, CompletionTokens: res.TotalUsage.OutputTokens}
		r.ResponseMessages = toLLMMessages(res.ResponseMessages)
		stream.SetResult(r)
	}()
	return stream, nil
}

func partsText(parts []llm.Part) string {
	var texts []string
	for _, p := range parts {
		if p.Type == llm.PartText && p.Text != "" {
			texts = append(texts, p.Text)
		}
	}
	return strings.Join(texts, "\n")
}

func toSDKMessage(msg llm.Message) provider.Message {
	content := make([]provider.Part, 0, len(msg.Content))
	for _, p := range msg.Content {
		content = append(content, provider.Part{
			Type:            provider.PartType(p.Type),
			Text:            p.Text,
			ToolCallID:      p.ToolCallID,
			ToolName:        p.ToolName,
			ToolInput:       p.ToolInput,
			ToolOutput:      p.ToolOutput,
			ProviderOptions: p.ProviderOptions,
		})
	}
	return provider.Message{
		Role:            provider.Role(msg.Role),
		Content:         content,
		ProviderOptions: msg.ProviderOptions,
	}
}

func toSDKTools(tools []llm.Tool) []sdk.Tool {
	if len(tools) == 0 {
		return nil
	}
	out := make([]sdk.Tool, 0, len(tools))
	for _, t := range tools {
		out = append(out, sdk.Tool{
			Name:        t.Name,
			Description: t.Description,
			InputSchema: t.InputSchema,
		})
	}
	return out
}

func toLLMToolCalls(calls []provider.ToolCall) []llm.ToolCall {
	if len(calls) == 0 {
		return nil
	}
	out := make([]llm.ToolCall, 0, len(calls))
	for _, c := range calls {
		out = append(out, llm.ToolCall{
			ID:       c.ID,
			Name:     c.Name,
			Input:    c.Input,
			Metadata: c.Metadata,
		})
	}
	return out
}

func toLLMMessages(msgs []provider.Message) []llm.Message {
	if len(msgs) == 0 {
		return nil
	}
	out := make([]llm.Message, 0, len(msgs))
	for _, m := range msgs {
		content := make([]llm.Part, 0, len(m.Content))
		for _, p := range m.Content {
			content = append(content, llm.Part{
				Type:            llm.PartType(p.Type),
				Text:            p.Text,
				ToolCallID:      p.ToolCallID,
				ToolName:        p.ToolName,
				ToolInput:       p.ToolInput,
				ToolOutput:      p.ToolOutput,
				ProviderOptions: p.ProviderOptions,
			})
		}
		out = append(out, llm.Message{
			Role:            llm.Role(m.Role),
			Content:         content,
			ProviderOptions: m.ProviderOptions,
		})
	}
	return out
}
