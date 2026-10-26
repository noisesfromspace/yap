package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// fakeClient is an in-memory Client for Manager tests.
type fakeClient struct {
	tools     []Tool
	results   map[string]Result
	closed    bool
	listCalls int
}

func (f *fakeClient) ListTools(context.Context) ([]Tool, error) {
	f.listCalls++
	return f.tools, nil
}

func (f *fakeClient) CallTool(_ context.Context, name string, _ json.RawMessage) (Result, error) {
	return f.results[name], nil
}

func (f *fakeClient) Close() error { f.closed = true; return nil }

// fakeDial builds a fakeClient per server, keyed by cfg.Command or cfg.URL.
func fakeDial(clients map[string]*fakeClient) Dial {
	return func(_ context.Context, cfg ServerConfig) (Client, error) {
		key := cfg.Command
		if key == "" {
			key = cfg.URL
		}
		c, ok := clients[key]
		if !ok {
			return nil, context.DeadlineExceeded
		}
		return c, nil
	}
}

func textResult(s string) Result {
	b, _ := json.Marshal(map[string]string{"type": "text", "text": s})
	return Result{Content: []json.RawMessage{b}}
}

func TestManagerSyncNamespacesAndDiscovers(t *testing.T) {
	a := &fakeClient{tools: []Tool{
		{Name: "search", Description: "d", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "do thing!", InputSchema: json.RawMessage(`{"type":"object"}`)},
	}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))

	tools, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"a": {Command: "a"},
	})
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	want := map[string]bool{"mcp_a_search": true, "mcp_a_do_thing_": true}
	if len(tools) != 2 {
		t.Fatalf("got %d tools, want 2: %+v", len(tools), tools)
	}
	for _, tool := range tools {
		if !want[tool.Name] {
			t.Errorf("unexpected tool %q", tool.Name)
		}
	}
}

func TestManagerSyncFiltersAllowlist(t *testing.T) {
	a := &fakeClient{tools: []Tool{
		{Name: "one", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "two", InputSchema: json.RawMessage(`{"type":"object"}`)},
	}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))

	tools, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"a": {Command: "a", Tools: []string{"one"}},
	})
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if len(tools) != 1 || tools[0].Name != "mcp_a_one" {
		t.Fatalf("got %+v, want only mcp_a_one", tools)
	}
}

func TestManagerSyncUnavailableServerIsNonFatal(t *testing.T) {
	a := &fakeClient{tools: []Tool{{Name: "search", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))

	tools, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"a": {Command: "a"},
		"b": {Command: "b"}, // no fake client -> dial fails
	})
	if len(errs) != 1 {
		t.Fatalf("want 1 error, got %v", errs)
	}
	if len(tools) != 1 || tools[0].Name != "mcp_a_search" {
		t.Fatalf("got %+v, want mcp_a_search despite b failing", tools)
	}
}

func TestManagerCallRoutesAndNormalizes(t *testing.T) {
	a := &fakeClient{
		tools: []Tool{{Name: "search", InputSchema: json.RawMessage(`{"type":"object"}`)}},
		results: map[string]Result{
			"search": textResult("hello"),
		},
	}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))
	if _, errs := m.Sync(context.Background(), map[string]ServerConfig{"a": {Command: "a"}}); len(errs) != 0 {
		t.Fatalf("sync: %v", errs)
	}
	out, err := m.Call(context.Background(), "mcp_a_search", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	if out != "hello" {
		t.Fatalf("got %q, want hello", out)
	}
}

func TestResultTextPreferences(t *testing.T) {
	// Structured content wins over duplicate text JSON.
	structured := `{"a":1}`
	r := Result{
		StructuredContent: json.RawMessage(structured),
		Content: []json.RawMessage{
			json.RawMessage(`{"type":"text","text":"` + structured + `"}`),
		},
	}
	if got := r.Text(); got != structured {
		t.Fatalf("got %q, want %q", got, structured)
	}

	// Error surfaces text with a prefix.
	r = Result{IsError: true, Content: []json.RawMessage{
		json.RawMessage(`{"type":"text","text":"bad"}`),
	}}
	if got := r.Text(); got != "Error: bad" {
		t.Fatalf("got %q, want error text", got)
	}

	// Unsupported blocks are summarized.
	r = Result{Content: []json.RawMessage{
		json.RawMessage(`{"type":"image","data":"..."}`),
	}}
	if got := r.Text(); !strings.Contains(got, "unsupported content: image") {
		t.Fatalf("got %q, want unsupported summary", got)
	}
}

func TestManagerSyncCachesToolList(t *testing.T) {
	a := &fakeClient{tools: []Tool{{Name: "t", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))
	cfg := map[string]ServerConfig{"s": {Command: "a"}}

	// Two Syncs with unchanged config list tools once.
	for i := 0; i < 2; i++ {
		if _, errs := m.Sync(context.Background(), cfg); len(errs) != 0 {
			t.Fatalf("sync%d: %v", i, errs)
		}
	}
	if a.listCalls != 1 {
		t.Fatalf("ListTools called %d times, want 1 (tools should be cached per connection)", a.listCalls)
	}

	// A config change reconnects and re-lists.
	cfg["s"] = ServerConfig{Command: "a", Tools: []string{"t"}}
	if _, errs := m.Sync(context.Background(), cfg); len(errs) != 0 {
		t.Fatalf("sync after config change: %v", errs)
	}
	if a.listCalls != 2 {
		t.Fatalf("ListTools called %d times after config change, want 2", a.listCalls)
	}
}

func TestManagerSyncReconnectsOnConfigChange(t *testing.T) {
	a := &fakeClient{tools: []Tool{{Name: "t", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	b := &fakeClient{tools: []Tool{{Name: "t", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	m := NewManager(fakeDial(map[string]*fakeClient{"x": a, "y": b}))

	if _, errs := m.Sync(context.Background(), map[string]ServerConfig{"s": {Command: "x"}}); len(errs) != 0 {
		t.Fatalf("sync1: %v", errs)
	}
	if a.closed {
		t.Fatal("a closed prematurely")
	}
	if _, errs := m.Sync(context.Background(), map[string]ServerConfig{"s": {Command: "y"}}); len(errs) != 0 {
		t.Fatalf("sync2: %v", errs)
	}
	if !a.closed {
		t.Fatal("a not closed after config change")
	}

	// Removing the server closes it.
	if _, errs := m.Sync(context.Background(), map[string]ServerConfig{}); len(errs) != 0 {
		t.Fatalf("sync3: %v", errs)
	}
	if !b.closed {
		t.Fatal("b not closed after removal")
	}
}

func TestManagerLazyServer(t *testing.T) {
	a := &fakeClient{tools: []Tool{
		{Name: "search", Description: "find things across the index", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "get", Description: "get one record", InputSchema: json.RawMessage(`{"type":"object"}`)},
	}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))

	// A lazy server exposes exactly one loader tool, not its real tools.
	got, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"a": {Command: "a", Lazy: true},
	})
	if len(errs) != 0 {
		t.Fatalf("unexpected errors: %v", errs)
	}
	if len(got) != 1 {
		t.Fatalf("lazy server should expose one loader, got %d: %+v", len(got), got)
	}
	lt := got[0]
	if !lt.Loader || lt.Server != "a" {
		t.Fatalf("loader tool wrong: %+v", lt)
	}
	if lt.Name != "mcp_a" {
		t.Fatalf("loader name = %q, want mcp_a", lt.Name)
	}
	if !strings.Contains(lt.Description, "search") || !strings.Contains(lt.Description, "get") {
		t.Fatalf("loader description missing tool names: %q", lt.Description)
	}

	// Activate returns the server's real tools, ready to register.
	act, err := m.Activate("a")
	if err != nil {
		t.Fatal(err)
	}
	if len(act) != 2 {
		t.Fatalf("activate returned %d tools, want 2: %+v", len(act), act)
	}
	names := map[string]bool{}
	for _, x := range act {
		names[x.Name] = true
		if x.Loader {
			t.Fatalf("activated tool %q still marked loader", x.Name)
		}
	}
	if !names["mcp_a_search"] || !names["mcp_a_get"] {
		t.Fatalf("activate names wrong: %v", names)
	}

	// Activating a non-lazy server is an error.
	b := &fakeClient{tools: []Tool{{Name: "t", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	m2 := NewManager(fakeDial(map[string]*fakeClient{"b": b}))
	if _, errs := m2.Sync(context.Background(), map[string]ServerConfig{"b": {Command: "b"}}); len(errs) != 0 {
		t.Fatalf("sync b: %v", errs)
	}
	if _, err := m2.Activate("b"); err == nil {
		t.Fatal("Activate on a non-lazy server should error")
	}
}

func TestSanitize(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"search", "search"},
		{"get_host", "get_host"},
		{"bad name!", "bad_name_"},
		{"", "tool"},
		{"list_repository_collaborator", "list_repository_collaborator"}, // exactly 28 runes, not truncated
	}
	for _, c := range cases {
		if got := sanitize(c.in); got != c.want {
			t.Errorf("sanitize(%q) = %q, want %q", c.in, got, c.want)
		}
	}

	// Long names sharing a prefix must not collide.
	groups := sanitize("list_available_data_definition_groups")
	defs := sanitize("list_available_data_definitions")
	if groups == defs {
		t.Fatalf("long names collide: %q", groups)
	}
	for _, n := range []string{groups, defs} {
		if len(n) != 28 {
			t.Errorf("sanitized long name %q is %d runes, want 28", n, len(n))
		}
	}
}
