// Package goai adapts the GoAI SDK to Yap's provider surface. It is the only
// package in the repository that imports github.com/zendev-sh/goai (and its
// provider subpackages); the agent loop and tools only see Yap-owned types.
package goai

import (
	"context"
	"errors"
	"fmt"
	"net"
	"net/http"
	"strings"

	sdk "github.com/zendev-sh/goai"
	"github.com/zendev-sh/goai/provider"
	"github.com/zendev-sh/goai/provider/anthropic"
	"github.com/zendev-sh/goai/provider/compat"
	"github.com/zendev-sh/goai/provider/deepseek"
	"github.com/zendev-sh/goai/provider/google"
	"github.com/zendev-sh/goai/provider/openai"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/wire"
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

// IsRetryable reports whether err is a transient error worth retrying: a
// provider API error flagged retryable (429, 5xx, OpenAI 404), or a
// network-level error (timeout, connection reset/refused, DNS). Context
// cancellation/deadline is deliberately not retryable. It mirrors the SDK's
// own classifier so the agent can decide whether a mid-stream failure is safe
// to retry; the SDK already retries pre-stream failures (MaxRetries).
func IsRetryable(err error) bool {
	if err == nil {
		return false
	}
	var apiErr *sdk.APIError
	if errors.As(err, &apiErr) {
		return apiErr.IsRetryable
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return false
	}
	var netErr net.Error
	if errors.As(err, &netErr) {
		return true
	}
	msg := err.Error()
	return strings.Contains(msg, "connection reset by peer") ||
		strings.Contains(msg, "connection refused") ||
		strings.Contains(msg, "TLS handshake timeout") ||
		strings.Contains(msg, "no such host") ||
		strings.Contains(msg, "i/o timeout")
}

// Classify maps a provider error onto Yap's wire error codes (utils.Code*)
// plus a small machine-readable data payload, so the frontend branches on a
// code instead of string-matching the message. APIError first (its status
// code separates auth from rate-limit), then the context-overflow sentinel,
// then network-level errors; anything else is an internal error.
func Classify(err error) (int, map[string]any) {
	if err == nil {
		return wire.CodeInternal, nil
	}
	var apiErr *sdk.APIError
	if errors.As(err, &apiErr) {
		data := map[string]any{"status": apiErr.StatusCode}
		if apiErr.IsRetryable {
			data["retryable"] = true
		}
		switch apiErr.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return wire.CodeAuth, data
		case http.StatusTooManyRequests:
			return wire.CodeRateLimited, data
		default:
			return wire.CodeInternal, data
		}
	}
	var overflow *sdk.ContextOverflowError
	if errors.As(err, &overflow) {
		return wire.CodeContextOverflow, nil
	}
	if IsRetryable(err) {
		return wire.CodeNetwork, map[string]any{"retryable": true}
	}
	return wire.CodeInternal, nil
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
// reasoning work, plus the user's reasoning_level mapped to each provider's
// native knob. They are confined to this adapter; the agent never sees them.
// Google already defaults includeThoughts=true for thinking-capable models and
// DeepSeek streams reasoning_content natively (its provider is built with
// IncludeReasoningContent), so those need no request option unless a level is
// requested. An empty level means "provider default".
func (m *modelImpl) providerOptions(level string) map[string]any {
	id := strings.ToLower(m.model.ModelID())
	switch m.name {
	case "openai":
		// Responses API (default): stream a visible reasoning summary and
		// preserve encrypted reasoning items for tool continuation. Do not
		// send reasoning options to non-reasoning models: they reject them.
		if isOpenAIReasoningModel(id) {
			opts := map[string]any{"reasoning_summary": "auto"}
			if level != "" {
				opts["reasoning_effort"] = level
			}
			return opts
		}
	case "anthropic":
		// Current adaptive-thinking models can return a visible summary.
		if supportsAnthropicAdaptiveThinking(id) {
			opts := map[string]any{"thinking": map[string]any{"type": "adaptive", "display": "summarized"}}
			if level != "" {
				opts["effort"] = level
			}
			return opts
		}
		// Older thinking-capable Claude models require a token budget rather
		// than adaptive mode; a higher level buys a bigger budget. Leave still
		// older models untouched.
		if supportsAnthropicExtendedThinking(id) {
			budget := 4096
			switch level {
			case "low":
				budget = 1024
			case "high":
				budget = 16384
			}
			return map[string]any{"thinking": map[string]any{"type": "enabled", "budgetTokens": budget}}
		}
	case "google", "gemini":
		// Thinking is on by default for thinking models; the only user-facing
		// level is thinkingLevel (low|high), so medium/max collapse to high.
		if level != "" {
			gl := level
			if gl == "medium" || gl == "max" {
				gl = "high"
			}
			return map[string]any{"thinkingConfig": map[string]any{"includeThoughts": true, "thinkingLevel": gl}}
		}
	case "deepseek":
		// DeepSeek V4 and reasoning models require thinking to be enabled;
		// the native adapter also replays their reasoning_content unchanged.
		if strings.Contains(id, "v4") || strings.Contains(id, "reasoner") || strings.Contains(id, "r1") {
			return map[string]any{"thinking": map[string]any{"type": "enabled"}}
		}
	default:
		// OpenAI-compatible endpoints (compat): forward the effort verbatim;
		// most reasoning endpoints accept a top-level reasoning_effort.
		if level != "" {
			return map[string]any{"reasoning_effort": level}
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
	if po := m.providerOptions(params.ReasoningLevel); po != nil {
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
		r.ToolCalls = toLLMToolCalls(res.ToolCalls)
		r.FinishReason = string(res.FinishReason)
		r.Usage = toLLMUsage(m.name, res.TotalUsage)
		r.ResponseMessages = toLLMMessages(res.ResponseMessages)
		stream.SetResult(r)
	}()
	return stream, nil
}

// toLLMUsage maps the SDK's per-provider usage onto Yap's normalized shape.
// Google reports visible output (candidatesTokenCount) and thinking
// (thoughtsTokenCount) separately; both are billed at the output rate, so
// thinking is folded into completion. OpenAI and Anthropic already include
// reasoning inside output_tokens. CacheWriteTokens is Anthropic's cache
// creation (0 for providers that do not report it).
func toLLMUsage(name string, u provider.Usage) llm.Usage {
	completion := u.OutputTokens
	if name == "google" || name == "gemini" {
		completion += u.ReasoningTokens
	}
	return llm.Usage{
		PromptTokens:     u.InputTokens,
		CompletionTokens: completion,
		CacheReadTokens:  u.CacheReadTokens,
		CacheWriteTokens: u.CacheWriteTokens,
	}
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
			URL:             p.URL,
			ToolCallID:      p.ToolCallID,
			ToolName:        p.ToolName,
			ToolInput:       p.ToolInput,
			ToolOutput:      p.ToolOutput,
			CacheControl:    p.CacheControl,
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
			ID:    c.ID,
			Name:  c.Name,
			Input: c.Input,
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
				URL:             p.URL,
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
