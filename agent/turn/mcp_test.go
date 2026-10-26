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

// stubMCPClient records calls so activation cannot hide an extra invocation or
// a stale turn context. Its mutex also supports concurrent autoactivation.
type stubMCPClient struct {
	tools    []mcp.Tool
	mu       sync.Mutex
	calls    int
	contexts []context.Context
	closed   bool
}

func (s *stubMCPClient) ListTools(context.Context) ([]mcp.Tool, error) { return s.tools, nil }
func (s *stubMCPClient) CallTool(ctx context.Context, _ string, _ json.RawMessage) (mcp.Result, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	s.calls++
	s.contexts = append(s.contexts, ctx)
	if err := ctx.Err(); err != nil {
		return mcp.Result{}, err
	}
	b, _ := json.Marshal(map[string]string{"type": "text", "text": "answer sk-" + strings.Repeat("b", 32)})
	return mcp.Result{Content: []json.RawMessage{b}}, nil
}
func (s *stubMCPClient) Close() error { s.closed = true; return nil }

func lazyConfig() map[string]mcp.ServerConfig {
	return map[string]mcp.ServerConfig{"a": {Command: "a", Lazy: true}}
}

// useLazyServer points the process-wide manager at a lazy stub server for one test.
func useLazyServer(t *testing.T, extra ...mcp.Tool) *stubMCPClient {
	t.Helper()
	old := mcpMgr
	client := &stubMCPClient{tools: append([]mcp.Tool{{Name: "search", InputSchema: json.RawMessage(`{"type":"object","properties":{"q":{"type":"string"}},"required":["q"]}`)}}, extra...)}
	mcpMgr = mcp.NewManager(func(context.Context, mcp.ServerConfig) (mcp.Client, error) { return client, nil })
	t.Cleanup(func() {
		CloseMCP()
		mcpMgr = old
	})
	syncMCPTools(context.Background(), lazyConfig())
	return client
}

func searchCall() llm.ToolCall {
	return llm.ToolCall{Name: "mcp_a_search", Input: json.RawMessage(`{"q":"x"}`)}
}

func TestLazyAutoactivationSameCallAndValidation(t *testing.T) {
	c := useLazyServer(t)
	bad := searchCall()
	bad.Input = json.RawMessage(`{}`)
	if res := callTool(bad, nil); !strings.Contains(res.result, "invalid arguments") {
		t.Fatalf("validation: %q", res.result)
	}
	if c.calls != 0 {
		t.Fatal("invalid call reached server")
	}
	res := callTool(searchCall(), nil)
	if !strings.Contains(res.result, "answer") || strings.Contains(res.result, strings.Repeat("b", 32)) {
		t.Fatalf("result not executed/scrubbed: %q", res.result)
	}
	if c.calls != 1 {
		t.Fatalf("calls = %d", c.calls)
	}
}

func TestLazyUnknownAndAllowedListDoNotActivate(t *testing.T) {
	c := useLazyServer(t)
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
	if c.calls != 1 {
		t.Fatalf("calls = %d", c.calls)
	}
}

func TestLazyActivationPersistsWithCurrentContext(t *testing.T) {
	c := useLazyServer(t)
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
	if c.contexts[0] != first || c.contexts[1] != second {
		t.Fatal("stale turn context")
	}
	stop()
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "context canceled") {
		t.Fatal(res.result)
	}
	if c.calls != 3 {
		t.Fatalf("calls = %d; must not retry", c.calls)
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
	c := useLazyServer(t, mcp.Tool{Name: "broken", InputSchema: json.RawMessage(`{"type":"not-a-type"}`)})
	for i := 0; i < 2; i++ {
		res := callTool(llm.ToolCall{Name: "mcp_a", Input: json.RawMessage(`{}`)}, nil)
		if !strings.Contains(res.result, "error:") || !strings.Contains(res.result, "mcp_a_broken") || strings.Contains(res.result, "Loaded") {
			t.Fatal(res.result)
		}
	}
	if _, ok := tools.Get("mcp_a_broken"); ok {
		t.Fatal("bad schema registered")
	}
	if c.calls != 0 {
		t.Fatal("loader invoked server tool")
	}
	syncMCPTools(context.Background(), lazyConfig())
	res := callTool(llm.ToolCall{Name: "mcp_a_broken", Input: json.RawMessage(`{}`)}, nil)
	if !strings.Contains(res.result, "error:") {
		t.Fatal(res.result)
	}
}

func TestLazyRemovalConfigChangeAndClose(t *testing.T) {
	c := useLazyServer(t)
	callTool(searchCall(), nil)
	cfg := lazyConfig()
	sc := cfg["a"]
	sc.Args = []string{"changed"}
	cfg["a"] = sc
	syncMCPTools(context.Background(), cfg)
	if !c.closed {
		t.Fatal("changed connection not closed")
	}
	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("activation survived config change")
	}
	callTool(searchCall(), nil)
	c.closed = false
	syncMCPTools(context.Background(), nil)
	if !c.closed {
		t.Fatal("empty config did not close connection")
	}
	if _, ok := tools.Get("mcp_a"); ok {
		t.Fatal("loader survived removal")
	}
	if _, ok := mcpMgr.LazyServerFor("mcp_a_search"); ok {
		t.Fatal("ownership survived removal")
	}
	syncMCPTools(context.Background(), lazyConfig())
	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("activation survived removal/re-add")
	}
	callTool(searchCall(), nil)
	CloseMCP()
	syncMCPTools(context.Background(), lazyConfig())
	if _, ok := tools.Get("mcp_a_search"); ok {
		t.Fatal("activation survived Close")
	}
}

func TestConcurrentLazyAutoactivation(t *testing.T) {
	c := useLazyServer(t)
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
	if c.calls != 20 {
		t.Fatalf("calls = %d", c.calls)
	}
}

// Use a distinct name: guard declarations live for the test process lifetime.
func TestLazyAutoactivationStillRunsStaticGate(t *testing.T) {
	c := useLazyServer(t, mcp.Tool{Name: "guarded", InputSchema: json.RawMessage(`{"type":"object"}`)})
	tools.Gate[struct{}]("mcp_a_guarded", func(*struct{}) string { return "" }, safety.Rule{Name: "test guard", Always: true})
	res := callTool(llm.ToolCall{Name: "mcp_a_guarded", Input: json.RawMessage(`{}`)}, nil)
	if !strings.Contains(res.result, "approval requires") {
		t.Fatal(res.result)
	}
	if c.calls != 0 {
		t.Fatal("guarded autoactivated tool executed")
	}
}

func TestLazyValidToolSurvivesSiblingBadSchema(t *testing.T) {
	c := useLazyServer(t, mcp.Tool{Name: "broken", InputSchema: json.RawMessage(`{"type":"invalid"}`)})
	if res := callTool(searchCall(), nil); !strings.Contains(res.result, "answer") {
		t.Fatal(res.result)
	}
	if c.calls != 1 {
		t.Fatalf("calls = %d", c.calls)
	}
}
