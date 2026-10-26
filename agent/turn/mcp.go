package turn

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"

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
// servers contribute their cached tool list without re-listing. A lazy server
// contributes one loader tool instead of its tools; activating it registers
// them for the rest of the turn. An unavailable server is a warning on
// stderr, not a failed turn: the tools it would have contributed are simply
// absent.
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
		if t.Loader {
			registerLoader(ctx, t)
			continue
		}
		registerMCPTool(ctx, t)
	}
}

// lazyHint explains a call to a tool name that is not registered. Activation
// is per turn, so a lazy server's tools are the one case where the model can
// name a real tool that is merely not loaded yet; telling it which loader to
// call turns that dead end into one extra step.
func lazyHint(name string) string {
	if _, ok := tools.Get(name); ok {
		return "" // registered, so a miss here is not ours to explain
	}
	loader, ok := mcpMgr.LoaderFor(name)
	if !ok {
		return ""
	}
	return fmt.Sprintf("error: unknown tool %s: that MCP server is lazy, so its tools must be loaded once per turn. Call %s first, then call %s again.", name, loader, name)
}

// registerMCPTool registers one discovered MCP tool, routed to mcpMgr.Call.
func registerMCPTool(ctx context.Context, t mcp.Tool) {
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

// registerLoader wires a lazy server's loader tool. Calling it activates the
// server: its real tools are registered (so the next model request can call
// them) and a summary is returned naming what became available.
func registerLoader(ctx context.Context, t mcp.Tool) {
	server := t.Server
	err := tools.RegisterRaw(t.Name, t.Description, t.InputSchema, func(raw json.RawMessage) (string, string, error) {
		list, err := mcpMgr.Activate(server)
		if err != nil {
			return "", "", err
		}
		var names []string
		for _, lt := range list {
			if _, exists := tools.Get(lt.Name); exists {
				continue // already activated this turn
			}
			registerMCPTool(ctx, lt)
			names = append(names, lt.Name)
		}
		return fmt.Sprintf("Loaded %d tools from %q: %s. Call them directly; their full definitions are now in context.",
			len(names), server, strings.Join(names, ", ")), "", nil
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "yap: mcp:", err)
	}
}
