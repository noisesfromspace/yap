// Package llm defines Yap's own minimal model surface. The agent loop
// and harness speak these types; only the adapter in agent/llm/goai
// imports the GoAI SDK. Keeping this boundary means a provider SDK swap never
// touches the agent loop, tools, or the stdout wire protocol.
package llm

import (
	"context"
	"encoding/json"
)

type Role string

const (
	RoleSystem    Role = "system"
	RoleUser      Role = "user"
	RoleAssistant Role = "assistant"
	RoleTool      Role = "tool"
)

type PartType string

const (
	PartText       PartType = "text"
	PartImage      PartType = "image"
	PartReasoning  PartType = "reasoning"
	PartToolCall   PartType = "tool-call"
	PartToolResult PartType = "tool-result"
)

// Part is one content element of a Message. ProviderOptions carries opaque
// provider metadata that must round-trip for immediate tool continuation:
// OpenAI Responses reasoning items/encrypted content, Anthropic signatures,
// Gemini thought signatures, DeepSeek reasoning_content markers.
type Part struct {
	Type            PartType
	Text            string
	URL             string
	ToolCallID      string
	ToolName        string
	ToolInput       json.RawMessage
	ToolOutput      string
	ProviderOptions map[string]any
}

type Message struct {
	Role            Role
	Content         []Part
	ProviderOptions map[string]any
}

type ToolCall struct {
	ID    string
	Name  string
	Input json.RawMessage
}

type Tool struct {
	Name        string
	Description string
	InputSchema json.RawMessage
}

type Usage struct {
	PromptTokens     int
	CompletionTokens int
	// CacheReadTokens is the portion of PromptTokens served from the
	// provider's prompt cache. It is kept separate because some providers
	// (OpenAI, OpenAI-compatible, Google) already subtract it from
	// PromptTokens while others (Anthropic) leave it included; the agent
	// reconstructs the full prompt size for the context-fill gauge from
	// these two fields.
	CacheReadTokens int
}

type EventType string

const (
	EventReasoning EventType = "reasoning"
	EventText      EventType = "text"
)

// Event is a display-relevant stream chunk: reasoning (thinking) or
// assistant prose. Tool calls, usage and the final assistant message come
// from Result after the stream drains.
type Event struct {
	Type EventType
	Text string
}

// Result is one generation step's outcome.
type Result struct {
	Text         string
	ToolCalls    []ToolCall
	FinishReason string
	Usage        Usage
	// ResponseMessages is the exact assistant message GoAI produced for this
	// step, with ordered parts and provider metadata intact. Append verbatim
	// to history before tool continuation. Nil for an empty response.
	ResponseMessages []Message
	Err              error
}

type Params struct {
	Messages []Message
	Tools    []Tool
}

// Stream yields display events then, once drained, the final Result.
type Stream struct {
	Events <-chan Event
	done   chan struct{}
	result Result
}

func NewStream(events <-chan Event) *Stream {
	return &Stream{Events: events, done: make(chan struct{})}
}

// SetResult publishes the final result and unblocks Result.
func (s *Stream) SetResult(r Result) {
	s.result = r
	close(s.done)
}

// Result blocks until the stream drains and returns the step's result.
func (s *Stream) Result() Result {
	<-s.done
	return s.result
}

// LanguageModel is the Yap-owned provider surface: one generation step at a
// time (no auto tool loop). The agent runs its own tool loop.
type LanguageModel interface {
	DoStream(ctx context.Context, params Params) (*Stream, error)
}

// Provider constructs LanguageModels for a configured provider.
type Provider interface {
	Model(modelID string) LanguageModel
}

// ProviderConfig is the Yap-side configuration needed to build a provider.
type ProviderConfig struct {
	Name    string
	BaseURL string
	APIKey  string
}
