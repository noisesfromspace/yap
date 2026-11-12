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
		name:        cfg.Name,
		baseURL:     strings.TrimRight(cfg.BaseURL, "/"),
		apiKey:      cfg.APIKey,
		token:       cfg.Token,
		authOptions: cfg.AuthOptions,
	}, nil
}

// tokenSource adapts Yap's token callback to the SDK's TokenSource interface,
// so llm.ProviderConfig never has to import the SDK.
type tokenSource func(ctx context.Context) (string, error)

func (f tokenSource) Token(ctx context.Context) (string, error) { return f(ctx) }

// isNetworkError reports transport/connectivity failures (timeout, reset,
// refused, DNS), which are surfaced as network errors to the UI.
func isNetworkError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr)
}

// IsRetryable reports whether the turn loop should retry a transient server
// failure. Quota/rate-limit 429s and offline/network outages fail fast.
func IsRetryable(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, context.DeadlineExceeded) || errors.Is(err, context.Canceled) {
		return false
	}
	var apiErr *sdk.APIError
	if errors.As(err, &apiErr) {
		return apiErr.StatusCode >= http.StatusInternalServerError && apiErr.StatusCode != http.StatusNotImplemented && apiErr.IsRetryable
	}
	return false
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
		if IsRetryable(err) {
			data["retryable"] = true
		}
		switch apiErr.StatusCode {
		case http.StatusUnauthorized, http.StatusForbidden:
			return wire.CodeAuth, data
		case http.StatusTooManyRequests:
			return wire.CodeRateLimited, data
		default:
			// A retryable server-side failure (5xx) is a provider error, not
			// an internal bug; keep it distinct from transport (CodeNetwork).
			if apiErr.IsRetryable {
				return wire.CodeProviderServer, data
			}
			return wire.CodeInternal, data
		}
	}
	var overflow *sdk.ContextOverflowError
	if errors.As(err, &overflow) {
		return wire.CodeContextOverflow, nil
	}
	if isNetworkError(err) {
		return wire.CodeNetwork, nil
	}
	return wire.CodeInternal, nil
}

type providerImpl struct {
	name    string
	baseURL string
	apiKey  string
	// token, when set, is a refreshable login token (a subscription/plan
	// login); it replaces the static API key.
	token func(ctx context.Context) (string, error)
	// authOptions are request options the login route requires (nil for
	// API-key providers).
	authOptions map[string]any
}

func (p *providerImpl) Model(modelID string) llm.LanguageModel {
	var m provider.LanguageModel
	switch p.name {
	case "openai":
		var opts []openai.Option
		switch {
		case p.token != nil:
			// Sign in with ChatGPT: the SDK refreshes and sends this token as
			// the bearer credential, exactly as the public API expects.
			opts = append(opts, openai.WithTokenSource(tokenSource(p.token)))
		case p.apiKey != "":
			opts = append(opts, openai.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, openai.WithBaseURL(p.baseURL))
		}
		m = openai.Chat(modelID, opts...)
	case "anthropic":
		var opts []anthropic.Option
		if p.token != nil {
			opts = append(opts, anthropic.WithTokenSource(tokenSource(p.token)))
		} else if p.apiKey != "" {
			opts = append(opts, anthropic.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, anthropic.WithBaseURL(p.baseURL))
		}
		m = anthropic.Chat(modelID, opts...)
	case "google", "gemini":
		var opts []google.Option
		if p.token != nil {
			opts = append(opts, google.WithTokenSource(tokenSource(p.token)))
		} else if p.apiKey != "" {
			opts = append(opts, google.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, google.WithBaseURL(p.baseURL))
		}
		m = google.Chat(modelID, opts...)
	case "deepseek":
		var opts []deepseek.Option
		if p.token != nil {
			opts = append(opts, deepseek.WithTokenSource(tokenSource(p.token)))
		} else if p.apiKey != "" {
			opts = append(opts, deepseek.WithAPIKey(p.apiKey))
		}
		if p.baseURL != "" {
			opts = append(opts, deepseek.WithBaseURL(p.baseURL))
		}
		m = deepseek.Chat(modelID, opts...)
	default:
		var opts []compat.Option
		if p.token != nil {
			opts = append(opts, compat.WithTokenSource(tokenSource(p.token)))
		} else if p.apiKey != "" {
			opts = append(opts, compat.WithAPIKey(p.apiKey))
		}
		opts = append(opts, compat.WithBaseURL(p.baseURL))
		m = compat.Chat(modelID, opts...)
	}
	return &modelImpl{model: m, name: p.name, authOptions: p.authOptions}
}

type modelImpl struct {
	model provider.LanguageModel
	name  string
	// authOptions are request options the login route requires (e.g.
	// store=false for ChatGPT plan usage), merged into every request.
	authOptions map[string]any
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
		// Keep retries in one place (the turn loop) so request counts and
		// backoff stay predictable.
		sdk.WithMaxRetries(0),
	}
	if len(system) > 0 {
		opts = append(opts, sdk.WithSystem(strings.Join(system, "\n\n")))
	}
	// Anthropic only: cache the stable [tools + system] prefix. Its cache
	// prefix order is tools -> system -> messages, so a breakpoint on the
	// system prompt also covers the tool definitions (the largest part of the
	// prompt for MCP-heavy sessions). The 1h TTL survives gaps between turns
	// (long tool runs, human thinking) that a 5m cache would not. Other
	// providers ignore both options.
	if m.name == "anthropic" {
		opts = append(opts, sdk.WithPromptCaching(true), sdk.WithCacheTTL("1h"))
	}
	if len(m.authOptions) > 0 {
		opts = append(opts, sdk.WithProviderOptions(m.authOptions))
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
