package mcp

import (
	"context"
	"encoding/json"
	"strings"
	"testing"
)

// fakeClient is an in-memory Client for Manager tests.
type fakeClient struct {
	tools   []Tool
	results map[string]Result
	closed  bool
}

func (f *fakeClient) ListTools(context.Context) ([]Tool, error) { return f.tools, nil }

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
