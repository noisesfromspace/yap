package turn

import (
	"context"
	"encoding/json"
	"fmt"
	"os"
	"strings"
	"sync"

	"boers.email/yap/agent/mcp"
	"boers.email/yap/agent/mcp/official"
	"boers.email/yap/agent/tools"
)

var mcpRegistrationMu sync.Mutex

// mcpMgr lives for the backend's lifetime, like SSH control masters: servers
// stay connected across turns, and a stop() only cancels the in-flight call.
var mcpMgr = mcp.NewManager(mcp.Dial(official.Dial))

// CloseMCP disconnects every MCP server; called on backend shutdown.
func CloseMCP() {
	mcpRegistrationMu.Lock()
	defer mcpRegistrationMu.Unlock()
	mcpMgr.Close()
	tools.UnregisterPrefix("mcp_")
}

// syncMCPTools reconciles the MCP manager with cfg for this turn and registers
// the resulting tools in the registry, replacing whatever the previous turn
// registered. Discovery is cached per connection (see mcp.Manager): unchanged
// servers contribute their cached tool list without re-listing. A lazy server
// contributes a loader; activation persists on the unchanged connection.
// Each turn re-registers definitions with the current cancellation context.
// An unavailable server is a warning on
// stderr, not a failed turn: the tools it would have contributed are simply
// absent.
func syncMCPTools(ctx context.Context, cfg map[string]mcp.ServerConfig) {
	mcpRegistrationMu.Lock()
	defer mcpRegistrationMu.Unlock()
	mcpTurnContext = ctx
	tools.UnregisterPrefix("mcp_")
	list, errs := mcpMgr.Sync(ctx, cfg)
	for _, err := range errs {
		fmt.Fprintln(os.Stderr, "yap: mcp:", err)
	}
	for _, t := range list {
		if t.Loader {
			registerLoader(ctx, t)
			continue
		}
		if err := registerMCPTool(ctx, t); err != nil {
			fmt.Fprintln(os.Stderr, "yap: mcp:", err)
		}
	}
}

// autoactivateMCP resolves only known lazy tools. Registration uses the
// current turn's context, never an earlier turn's.
func autoactivateMCP(name string) error {
	mcpRegistrationMu.Lock()
	defer mcpRegistrationMu.Unlock()
	if _, ok := tools.Get(name); ok {
		return nil
	}
	server, ok := mcpMgr.LazyServerFor(name)
	if !ok {
		return nil
	}
	ctx := mcpTurnContext
	if ctx == nil {
		// A call outside a turn (tests, one-shot paths) still needs a live
		// context: the registered closure captures it.
		ctx = context.Background()
	}
	_, err := activateMCP(ctx, server)
	if _, ok := tools.Get(name); ok {
		if err != nil {
			fmt.Fprintln(os.Stderr, "yap: mcp:", err)
		}
		return nil
	}
	return err
}

// Protected by mcpRegistrationMu; refreshed even for an empty configuration.
var mcpTurnContext context.Context

// activateMCP is shared by explicit and automatic loading. A successful
// summary names only registered definitions; malformed schemas are errors.
func activateMCP(ctx context.Context, server string) ([]string, error) {
	list, err := mcpMgr.Activate(server)
	if err != nil {
		return nil, err
	}
	var names []string
	var errs []string
	for _, t := range list {
		if _, exists := tools.Get(t.Name); !exists {
			if err := registerMCPTool(ctx, t); err != nil {
				errs = append(errs, err.Error())
				continue
			}
		}
		names = append(names, t.Name)
	}
	if len(errs) > 0 {
		return names, fmt.Errorf("MCP server %q: %s", server, strings.Join(errs, "; "))
	}
	return names, nil
}

// registerMCPTool registers one discovered MCP tool, routed to mcpMgr.Call.
func registerMCPTool(ctx context.Context, t mcp.Tool) error {
	name := t.Name
	return tools.RegisterRaw(name, t.Description, t.InputSchema, func(raw json.RawMessage) (string, string, error) {
		out, err := mcpMgr.Call(ctx, name, raw)
		if err != nil {
			return "", "", err
		}
		return out, "", nil
	})
}

// registerLoader wires a lazy server's loader tool. Calling it activates the
// server: its real tools are registered (so the next model request can call
// them) and a summary is returned naming what became available.
func registerLoader(ctx context.Context, t mcp.Tool) {
	server := t.Server
	err := tools.RegisterRaw(t.Name, t.Description, t.InputSchema, func(raw json.RawMessage) (string, string, error) {
		mcpRegistrationMu.Lock()
		defer mcpRegistrationMu.Unlock()
		names, err := activateMCP(ctx, server)
		if err != nil {
			return "", "", err
		}
		return fmt.Sprintf("Loaded %d tools from %q: %s. Call them directly; their full definitions are now in context.",
			len(names), server, strings.Join(names, ", ")), "", nil
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, "yap: mcp:", err)
	}
}
