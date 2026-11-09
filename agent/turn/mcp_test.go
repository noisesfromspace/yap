package turn

import (
	"context"
	"encoding/json"
	"strings"
	"sync"
	"testing"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/mcp"
	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/tools"
)

// fakeManager is a controllable mcpBackend for the turn layer's MCP glue. It
// models one lazy server "a": Sync exposes only the loader until Activate is
// called, then exposes the loader plus the real tools, mirroring the parts of
// the real Manager the glue depends on. Its mutex also supports concurrent
// autoactivation.
type fakeManager struct {
	mu            sync.Mutex
	syncTools     []mcp.Tool // returned by Sync (normally the loader)
	activateTools []mcp.Tool // returned by Activate (the server's real tools)
	lazyServer    string     // server name LazyServerFor resolves; "" means unknown
	callOut       string
	callErr       error
	active        bool
	calls         int
	contexts      []context.Context
	closed        bool
}

func (f *fakeManager) Sync(context.Context, map[string]mcp.ServerConfig) ([]mcp.Tool, []error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	out := append([]mcp.Tool(nil), f.syncTools...)
	if f.active {
		out = append(out, f.activateTools...)
	}
	return out, nil
}

func (f *fakeManager) Call(ctx context.Context, _ string, _ json.RawMessage) (string, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.calls++
	f.contexts = append(f.contexts, ctx)
	if err := ctx.Err(); err != nil {
		return "", err
	}
	if f.callErr != nil {
		return "", f.callErr
	}
	return f.callOut, nil
}

func (f *fakeManager) Activate(string) ([]mcp.Tool, error) {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.active = true
	return f.activateTools, nil
}

func (f *fakeManager) LazyServerFor(name string) (string, bool) {
	f.mu.Lock()
	defer f.mu.Unlock()
	for _, t := range f.activateTools {
		if t.Name == name {
			return f.lazyServer, f.lazyServer != ""
		}
	}
	return "", false
}

func (f *fakeManager) Close() {
	f.mu.Lock()
	defer f.mu.Unlock()
	f.closed = true
}

func loaderTool() mcp.Tool {
	return mcp.Tool{
		Name:        "mcp_a",
		Description: "load the MCP server a tools",
		InputSchema: json.RawMessage(`{"type":"object"}`),
		Server:      "a",
		Loader:      true,
	}
}

func searchTool() mcp.Tool {
	return mcp.Tool{
		Name:        "mcp_a_search",
		InputSchema: json.RawMessage(`{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}`),
		Server:      "a",
	}
}

func lazyConfig() map[string]mcp.ServerConfig {
	return map[string]mcp.ServerConfig{"a": {Command: "a", Lazy: true}}
}

// useLazyServer points the process-wide MCP backend at a fake lazy server for
// one test.
func useLazyServer(t *testing.T, extra ...mcp.Tool) *fakeManager {
	t.Helper()
	old := mcpMgr
	fm := &fakeManager{
		syncTools:     []mcp.Tool{loaderTool()},
		activateTools: append([]mcp.Tool{searchTool()}, extra...),
		lazyServer:    "a",
		callOut:       "answer sk-" + strings.Repeat("b", 32),
	}
	mcpMgr = fm
	t.Cleanup(func() {
		CloseMCP()
		mcpMgr = old
	})
	syncMCPTools(context.Background(), lazyConfig())
	return fm
}

func searchCall() llm.ToolCall {
	return llm.ToolCall{Name: "mcp_a_search", Input: json.RawMessage(`{"q":"x"}`)}
}

func TestLazyAutoactivationSameCallAndValidation(t *testing.T) {
	fm := useLazyServer(t)
	bad := searchCall()
	bad.Input = json.RawMessage(`{}`)
	if res := callTool(bad, nil); !strings.Contains(res.result, "invalid arguments") {
		t.Fatalf("validation: %q", res.result)
	}
	if fm.calls != 0 {
		t.Fatal("invalid call reached server")
	}
	res := callTool(searchCall(), nil)
	if !strings.Contains(res.result, "answer") || strings.Contains(res.result, strings.Repeat("b", 32)) {
		t.Fatalf("result not executed/scrubbed: %q", res.result)
	}
	if fm.calls != 1 {
		t.Fatalf("calls = %d", fm.calls)
	}
}

func TestLazyUnknownAndAllowedListDoNotActivate(t *testing.T) {
	fm := useLazyServer(t)
	allowed := []string{"mcp_a"}
	if res := callTool(searchCall(), &allowed); res.result != "error: unknown tool mcp_a_search" {
		t.Fatal(res.result)
	}
	if res := callTool(llm.ToolCall{Name: "mcp_a_nope", Input: json.RawMessage(`{}`)}, nil); res.result != "error: unknown tool mcp_a_nope" {
		t.Fatal(res.result)
	}
	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("denied/unknown call activated server")
	}
	allowed = []string{"mcp_a_search"} // The loader itself need not be allowed.
	if res := callTool(searchCall(), &allowed); !strings.Contains(res.result, "answer") {
		t.Fatal(res.result)
	}
	allowed = nil
	if res := callTool(searchCall(), &allowed); !strings.Contains(res.result, "unknown tool") {
		t.Fatal(res.result)
	}
	if fm.calls != 1 {
		t.Fatalf("calls = %d", fm.calls)
	}
}

func TestLazyActivationPersistsWithCurrentContext(t *testing.T) {
	fm := useLazyServer(t)
	first, cancel := context.WithCancel(context.Background())
	syncMCPTools(first, lazyConfig())
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "answer") {
		t.Fatal(res.result)
	}
	cancel()
	second, stop := context.WithCancel(context.Background())
	defer stop()
	syncMCPTools(second, lazyConfig())
	if _, ok := tools.Get("mcp_a_search"); !ok {
		t.Fatal("activation lost across turns")
	}
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "answer") {
		t.Fatal(res.result)
	}
	if fm.contexts[0] != first || fm.contexts[1] != second {
		t.Fatal("stale turn context")
	}
	stop()
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "context canceled") {
		t.Fatal(res.result)
	}
	if fm.calls != 3 {
		t.Fatalf("calls = %d; must not retry", fm.calls)
	}
}

func TestLoaderIdempotenceAndBadSchema(t *testing.T) {
	useLazyServer(t)
	for i := 0; i < 2; i++ {
		res := callTool(llm.ToolCall{Name: "mcp_a", Input: json.RawMessage(`{}`)}, nil)
		if !strings.Contains(res.result, "Loaded 1 tools") || !strings.Contains(res.result, "mcp_a_search") {
			t.Fatal(res.result)
		}
	}
}

func TestLoaderReportsBadSchema(t *testing.T) {
	fm := useLazyServer(t, mcp.Tool{Name: "mcp_a_broken", InputSchema: json.RawMessage(`{"type":"not-a-type"}`)})
	for i := 0; i < 2; i++ {
		res := callTool(llm.ToolCall{Name: "mcp_a", Input: json.RawMessage(`{}`)}, nil)
		if !strings.Contains(res.result, "error:") || !strings.Contains(res.result, "mcp_a_broken") || strings.Contains(res.result, "Loaded") {
			t.Fatal(res.result)
		}
	}
	if _, ok := tools.Get("mcp_a_broken"); ok {
		t.Fatal("bad schema registered")
	}
	if fm.calls != 0 {
		t.Fatal("loader invoked server tool")
	}
}

func TestCloseMCPClosesAndUnregisters(t *testing.T) {
	fm := useLazyServer(t)
	callTool(searchCall(), nil) // activate, so mcp_a_search is registered
	if _, ok := tools.Get("mcp_a_search"); !ok {
		t.Fatal("tool not registered")
	}
	CloseMCP()
	if !fm.closed {
		t.Fatal("CloseMCP did not close the manager")
	}
	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("tool survived CloseMCP")
	}
}

func TestConcurrentLazyAutoactivation(t *testing.T) {
	fm := useLazyServer(t)
	var wg sync.WaitGroup
	for i := 0; i < 20; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			if res := callTool(searchCall(), nil); !strings.Contains(res.result, "answer") {
				t.Errorf("call: %q", res.result)
			}
			_ = tools.All()
		}()
	}
	wg.Wait()
	if fm.calls != 20 {
		t.Fatalf("calls = %d", fm.calls)
	}
}

// Use a distinct name: guard declarations live for the test process lifetime.
func TestLazyAutoactivationStillRunsStaticGate(t *testing.T) {
	fm := useLazyServer(t, mcp.Tool{Name: "mcp_a_guarded", InputSchema: json.RawMessage(`{"type":"object"}`)})
	tools.Gate[struct{}]("mcp_a_guarded", func(*struct{}) string { return "" }, safety.Rule{Name: "test guard", Match: func(string) bool { return true }})
	res := callTool(llm.ToolCall{Name: "mcp_a_guarded", Input: json.RawMessage(`{}`)}, nil)
	if !strings.Contains(res.result, "approval requires") {
		t.Fatal(res.result)
	}
	if fm.calls != 0 {
		t.Fatal("guarded autoactivated tool executed")
	}
}

func TestLazyValidToolSurvivesSiblingBadSchema(t *testing.T) {
	fm := useLazyServer(t, mcp.Tool{Name: "mcp_a_broken", InputSchema: json.RawMessage(`{"type":"invalid"}`)})
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "answer") {
		t.Fatal(res.result)
	}
	if fm.calls != 1 {
		t.Fatalf("calls = %d", fm.calls)
	}
}
