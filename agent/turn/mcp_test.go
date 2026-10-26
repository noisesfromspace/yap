package turn

import (
	"context"
	"encoding/json"
	"strings"
	"testing"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/mcp"
	"boers.email/yap/agent/tools"
)

// stubMCPClient serves one canned tool list, so a lazy server can be
// exercised without a real MCP server.
type stubMCPClient struct{ tools []mcp.Tool }

func (s stubMCPClient) ListTools(context.Context) ([]mcp.Tool, error) { return s.tools, nil }

func (s stubMCPClient) CallTool(context.Context, string, json.RawMessage) (mcp.Result, error) {
	return mcp.Result{}, nil
}

func (s stubMCPClient) Close() error { return nil }

// useLazyServer points the process-wide manager at a lazy stub server for one
// test.
func useLazyServer(t *testing.T) {
	t.Helper()
	old := mcpMgr
	mcpMgr = mcp.NewManager(func(context.Context, mcp.ServerConfig) (mcp.Client, error) {
		return stubMCPClient{tools: []mcp.Tool{
			{Name: "search", InputSchema: json.RawMessage(`{"type":"object"}`)},
		}}, nil
	})
	t.Cleanup(func() {
		mcpMgr.Close()
		mcpMgr = old
		tools.UnregisterPrefix("mcp_")
	})
	syncMCPTools(context.Background(), map[string]mcp.ServerConfig{
		"a": {Command: "a", Lazy: true},
	})
}

// TestLazyToolHint covers the per-turn activation cost: a call to a lazy
// server's tool in a later turn is unknown, and the error must say how to
// load it instead of dead-ending.
func TestLazyToolHint(t *testing.T) {
	useLazyServer(t)

	res := callTool(llm.ToolCall{Name: "mcp_a_search", Input: json.RawMessage(`{}`)}, nil)
	if !strings.Contains(res.result, "mcp_a") || !strings.Contains(res.result, "lazy") {
		t.Fatalf("hint missing from %q", res.result)
	}

	// Names no MCP server owns keep the plain error.
	res = callTool(llm.ToolCall{Name: "nope", Input: json.RawMessage(`{}`)}, nil)
	if res.result != "error: unknown tool nope" {
		t.Fatalf("got %q, want the plain unknown-tool error", res.result)
	}
}

// TestLoaderActivatesForTheTurn checks the documented loader contract end to
// end: unloaded before, callable after.
func TestLoaderActivatesForTheTurn(t *testing.T) {
	useLazyServer(t)

	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("lazy tool registered before activation")
	}
	loader, ok := tools.Get("mcp_a")
	if !ok {
		t.Fatal("loader tool not registered")
	}
	out, _, err := loader.Run(json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if !strings.Contains(out, "mcp_a_search") {
		t.Fatalf("loader summary = %q, want the tool it loaded", out)
	}
	if _, ok := tools.Get("mcp_a_search"); !ok {
		t.Fatal("tool not registered after activation")
	}
	if hint := lazyHint("mcp_a_search"); hint != "" {
		t.Fatalf("activated tool still hints: %q", hint)
	}
}
