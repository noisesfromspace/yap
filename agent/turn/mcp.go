package turn

import (
	"context"
	"encoding/json"
	"fmt"
	"os"

	"boers.email/yap/agent/mcp"
	"boers.email/yap/agent/mcp/official"
	"boers.email/yap/agent/tools"
)

// mcpMgr lives for the backend's lifetime, like SSH control masters: servers
// stay connected across turns, and a stop() only cancels the in-flight call.
var mcpMgr = mcp.NewManager(mcp.Dial(official.Dial))

// CloseMCP disconnects every MCP server; called on backend shutdown.
func CloseMCP() { mcpMgr.Close() }

// syncMCPTools reconciles the MCP manager with cfg for this turn and registers
// the resulting tools in the registry, replacing whatever the previous turn
// registered. Discovery is cached per connection (see mcp.Manager): unchanged
// servers contribute their cached tool list without re-listing. An unavailable
// server is a warning on stderr, not a failed turn: the tools it would have
// contributed are simply absent.
func syncMCPTools(ctx context.Context, cfg map[string]mcp.ServerConfig) {
	tools.UnregisterPrefix("mcp_")
	if len(cfg) == 0 {
		return
	}
	list, errs := mcpMgr.Sync(ctx, cfg)
	for _, err := range errs {
		fmt.Fprintln(os.Stderr, "yap: mcp:", err)
	}
	for _, t := range list {
		t := t
		name := t.Name
		err := tools.RegisterRaw(name, t.Description, t.InputSchema, func(raw json.RawMessage) (string, string, error) {
			out, err := mcpMgr.Call(ctx, name, raw)
			if err != nil {
				return "", "", err
			}
			return out, "", nil
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, "yap: mcp:", err)
		}
	}
}
