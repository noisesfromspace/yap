// Package mcp defines Yap's MCP client boundary. Only adapters import an SDK;
// the agent loop and tool registry see only these types.
package mcp

import (
	"context"
	"encoding/json"
)

// ServerConfig is one MCP server from user-controlled settings.json. Env and
// Headers map destination names to environment-variable names, never
// credential values.
type ServerConfig struct {
	// Transport selects the connection: "stdio" or "http" (Streamable HTTP).
	// Empty infers from which of Command/URL is set.
	Transport string `json:"transport,omitempty"`

	// stdio: a local server launched as a subprocess.
	Command string   `json:"command,omitempty"`
	Args    []string `json:"args,omitempty"`
	Cwd     string   `json:"cwd,omitempty"`
	// Env maps a variable name for the child to an environment-variable name
	// in Yap's own environment. The child gets a minimal environment (PATH,
	// HOME) plus these resolved variables; Yap's full environment is never
	// inherited.
	Env map[string]string `json:"env,omitempty"`

	// http: a remote Streamable HTTP endpoint.
	URL string `json:"url,omitempty"`
	// Headers maps an HTTP header name to an environment-variable name whose
	// value is sent with every request (e.g. "x-api-key" -> "EXA_API_KEY").
	// A value may carry a literal scheme prefix separated by a single space
	// (e.g. "Bearer CENSYS_API_KEY" sends "Authorization: Bearer <value>").
	Headers map[string]string `json:"headers,omitempty"`

	// Tools selects which of the server's tools to expose. nil (omitted)
	// exposes all; an explicit empty list exposes none.
	Tools []string `json:"tools,omitempty"`

	// Lazy defers a server's tool definitions: instead of exposing every tool
	// in context every turn, a single loader tool (mcp_<server>) summarizes
	// what the server offers, and the definitions enter context only once they
	// are needed. Calling a listed tool directly also works: the call activates
	// the server and then runs, so lazy never costs a round-trip. Activation
	// persists for the connection (the backend's lifetime); a config change
	// re-arms it. Use for situational servers (a debugger, reverse-engineering
	// tool, ...) whose definitions would otherwise bloat every turn's context.
	Lazy bool `json:"lazy,omitempty"`
}

// Tool is a discovered MCP tool, as exposed to the provider.
type Tool struct {
	Name        string
	Description string
	InputSchema json.RawMessage
	// Server is the originating server name (set for every MCP tool).
	Server string
	// Loader marks a lazy server's single loader tool: calling it activates
	// the server's real tools rather than running a server tool.
	Loader bool
}

// Result is one tool call's raw outcome. Content holds the server's content
// blocks as raw JSON; StructuredContent is set when the server returned
// structured output.
type Result struct {
	Content           []json.RawMessage
	StructuredContent json.RawMessage
	IsError           bool
}

// Client is one connected MCP server.
type Client interface {
	ListTools(context.Context) ([]Tool, error)
	CallTool(context.Context, string, json.RawMessage) (Result, error)
	Close() error
}

// Dial connects to one server. Adapters implement it; the default is the
// official Go SDK adapter in agent/mcp/official.
type Dial func(context.Context, ServerConfig) (Client, error)
