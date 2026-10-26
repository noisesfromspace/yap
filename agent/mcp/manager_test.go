package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"strings"
	"testing"
	"time"
	"unicode/utf8"
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
		max  int
		want string
	}{
		{"search", 58, "search"},
		{"get_host", 58, "get_host"},
		{"bad name!", 58, "bad_name_"},
		{"", 58, "tool"},
		// Fits the budget exactly, so it is left alone.
		{"list_repository_collaborator", 58, "list_repository_collaborator"},
	}
	for _, c := range cases {
		if got := sanitize(c.in, c.max); got != c.want {
			t.Errorf("sanitize(%q, %d) = %q, want %q", c.in, c.max, got, c.want)
		}
	}

	// Long names sharing a prefix must not collide, and must respect the
	// budget they were given.
	groups := sanitize("list_available_data_definition_groups", 20)
	defs := sanitize("list_available_data_definitions", 20)
	if groups == defs {
		t.Fatalf("long names collide: %q", groups)
	}
	for _, n := range []string{groups, defs} {
		if len(n) != 20 {
			t.Errorf("sanitized long name %q is %d runes, want 20", n, len(n))
		}
	}

	// A budget too small for the hash suffix still truncates, never panics.
	if got := sanitize("abcdef", 5); got != "abcde" {
		t.Errorf("sanitize(abcdef, 5) = %q, want abcde", got)
	}
}

func TestPublicNameBudget(t *testing.T) {
	// The budget covers the whole provider name, not a fixed slice of the
	// tool part: this used to come out as decompile_function_<hash> even
	// though the full name fits comfortably.
	if got, want := publicName("ghidra", "decompile_function_by_address"), "mcp_ghidra_decompile_function_by_address"; got != want {
		t.Fatalf("publicName = %q, want %q", got, want)
	}

	// A long server name spends the server part, not the tool part, and the
	// total stays within the provider limit.
	long := strings.Repeat("s", 40)
	got := publicName(long, "decompile_function")
	if len(got) > maxToolNameRunes {
		t.Fatalf("public name %q is %d runes, want <= %d", got, len(got), maxToolNameRunes)
	}
	if !strings.HasSuffix(got, "decompile_function") {
		t.Fatalf("tool part was truncated: %q", got)
	}
	if publicName(long+"a", "t") == publicName(long+"b", "t") {
		t.Fatal("two long server names collapsed onto one public name")
	}
}

func TestClipKeepsRunesWhole(t *testing.T) {
	// Truncating by bytes would cut the third é in half.
	got := clip("éééééééééé", 4)
	if !utf8.ValidString(got) {
		t.Fatalf("clip split a rune: %q", got)
	}
	if utf8.RuneCountInString(got) != 5 { // 4 runes + ellipsis
		t.Fatalf("clip = %q, want 4 runes plus an ellipsis", got)
	}
	if got := clip("  a \n b  ", 20); got != "a b" {
		t.Fatalf("clip whitespace = %q, want %q", got, "a b")
	}
}

func TestManagerSyncKeepsServerWhenToolNamesCollide(t *testing.T) {
	a := &fakeClient{tools: []Tool{
		{Name: "get.host", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "get_host", InputSchema: json.RawMessage(`{"type":"object"}`)},
		{Name: "other", InputSchema: json.RawMessage(`{"type":"object"}`)},
	}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))
	cfg := map[string]ServerConfig{"a": {Command: "a"}}

	// A collision costs one tool and a warning, never the server: it once
	// failed Sync outright and left the server with no tools at all.
	got, errs := m.Sync(context.Background(), cfg)
	if len(got) != 2 {
		t.Fatalf("got %d tools, want 2: %+v", len(got), got)
	}
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "both map to") {
		t.Fatalf("want one collision warning, got %v", errs)
	}

	// The warning is reported on the Sync that loads the server, not every
	// turn afterwards.
	if _, errs := m.Sync(context.Background(), cfg); len(errs) != 0 {
		t.Fatalf("warning repeated on a later Sync: %v", errs)
	}
}

func TestManagerLazyServerFor(t *testing.T) {
	a := &fakeClient{tools: []Tool{{Name: "search", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	b := &fakeClient{tools: []Tool{{Name: "search", InputSchema: json.RawMessage(`{"type":"object"}`)}}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a, "b": b}))
	if _, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"a": {Command: "a", Lazy: true},
		"b": {Command: "b"},
	}); len(errs) != 0 {
		t.Fatalf("sync: %v", errs)
	}

	if loader, ok := m.LazyServerFor("mcp_a_search"); !ok || loader != "a" {
		t.Fatalf("LazyServerFor(mcp_a_search) = %q, %v; want a, true", loader, ok)
	}
	// A non-lazy server's tool is registered every turn, so there is nothing
	// to hint at; neither is a name no server owns.
	if _, ok := m.LazyServerFor("mcp_b_search"); ok {
		t.Fatal("non-lazy server reported a loader")
	}
	if _, ok := m.LazyServerFor("mcp_a_nope"); ok {
		t.Fatal("unknown tool reported a loader")
	}
}

func TestLoaderDescriptionListsCallableNames(t *testing.T) {
	a := &fakeClient{tools: []Tool{{
		Name:        "decompile_function_by_address",
		Description: "decompile the function at an address",
		InputSchema: json.RawMessage(`{"type":"object"}`),
	}}}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": a}))
	got, errs := m.Sync(context.Background(), map[string]ServerConfig{"a": {Command: "a", Lazy: true}})
	if len(errs) != 0 {
		t.Fatalf("sync: %v", errs)
	}
	// The summary must name the tool the model can call, not the server's
	// internal name for it.
	if !strings.Contains(got[0].Description, "mcp_a_decompile_function_by_address") {
		t.Fatalf("loader summary lacks the callable name: %q", got[0].Description)
	}
}

func TestLoaderDescriptionIsCapped(t *testing.T) {
	var many []Tool
	for i := 0; i < 200; i++ {
		many = append(many, Tool{
			Name:        fmt.Sprintf("tool_%03d", i),
			Description: strings.Repeat("d", 80),
			InputSchema: json.RawMessage(`{"type":"object"}`),
		})
	}
	m := NewManager(fakeDial(map[string]*fakeClient{"a": {tools: many}}))
	got, errs := m.Sync(context.Background(), map[string]ServerConfig{"a": {Command: "a", Lazy: true}})
	if len(errs) != 0 {
		t.Fatalf("sync: %v", errs)
	}
	// A big server must not put more text in context than the eager
	// definitions lazy mode replaces.
	if n := len(got[0].Description); n > maxLoaderDescription+100 {
		t.Fatalf("loader description is %d bytes, want ~%d", n, maxLoaderDescription)
	}
	if !strings.Contains(got[0].Description, "more not listed here") {
		t.Fatalf("capped summary does not say what is missing: %q", got[0].Description)
	}
}

func TestManagerSyncTimesOutHungServer(t *testing.T) {
	hanging := func(ctx context.Context, _ ServerConfig) (Client, error) {
		<-ctx.Done() // never answers initialize
		return nil, ctx.Err()
	}
	ok := &fakeClient{tools: []Tool{{Name: "t", InputSchema: json.RawMessage(`{"type":"object"}`)}}}

	defer func(d time.Duration) { syncTimeout = d }(syncTimeout)
	syncTimeout = 20 * time.Millisecond

	m := NewManager(func(ctx context.Context, cfg ServerConfig) (Client, error) {
		if cfg.URL == "hang" {
			return hanging(ctx, cfg)
		}
		return ok, nil
	})

	start := time.Now()
	got, errs := m.Sync(context.Background(), map[string]ServerConfig{
		"hang": {URL: "hang"},
		"ok":   {URL: "ok"},
	})
	// Sync holds the manager lock while dialing, so a server that never
	// answers must be cut loose rather than stall the turn.
	if len(errs) != 1 || !strings.Contains(errs[0].Error(), "hang") {
		t.Fatalf("want one error for the hung server, got %v", errs)
	}
	if len(got) != 1 || got[0].Name != "mcp_ok_t" {
		t.Fatalf("healthy server lost: %+v", got)
	}
	if elapsed := time.Since(start); elapsed > 5*time.Second {
		t.Fatalf("Sync took %v, want it bounded by syncTimeout", elapsed)
	}
}

// Names can collide across sanitized server names, or because a loader's
// name is also another server's tool name. Discovery, activation, and Call
// must all pick the same deterministic owner, even while tools are unloaded.
func TestManagerCrossServerOwnership(t *testing.T) {
	for _, tc := range []struct {
		name, first, second, firstTool, secondTool, shared string
		firstLazy, secondLazy                              bool
		loader                                             bool
	}{
		{name: "sanitized", first: "a!", second: "a?", firstTool: "search", secondTool: "search", shared: "mcp_a__search", firstLazy: true, secondLazy: true},
		{name: "tool beats loader", first: "a", second: "a_search", firstTool: "search", secondTool: "other", shared: "mcp_a_search", firstLazy: true, secondLazy: true},
		{name: "loader beats tool", first: "!_b", second: "_", firstTool: "other", secondTool: "b", shared: "mcp___b", firstLazy: true, secondLazy: false, loader: true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			a := &fakeClient{tools: []Tool{{Name: tc.firstTool, InputSchema: json.RawMessage(`{"type":"object"}`)}}, results: map[string]Result{tc.firstTool: textResult("first")}}
			b := &fakeClient{tools: []Tool{{Name: tc.secondTool, InputSchema: json.RawMessage(`{"type":"object"}`)}}, results: map[string]Result{tc.secondTool: textResult("second")}}
			m := NewManager(fakeDial(map[string]*fakeClient{"first": a, "second": b}))
			cfg := map[string]ServerConfig{tc.first: {Command: "first", Lazy: tc.firstLazy}, tc.second: {Command: "second", Lazy: tc.secondLazy}}
			for i := 0; i < 10; i++ {
				_, errs := m.Sync(context.Background(), cfg)
				if len(errs) == 0 {
					t.Fatal("collision not reported")
				}
				list, err := m.Activate(tc.first)
				if err != nil {
					t.Fatal(err)
				}
				for _, tool := range list {
					if tool.Name == tc.shared && tc.loader {
						t.Fatal("loader exposed as real tool")
					}
				}
				if tc.secondLazy {
					list, err = m.Activate(tc.second)
					if err != nil {
						t.Fatal(err)
					}
					for _, tool := range list {
						if tool.Name == tc.shared {
							t.Fatal("losing server exposed shared name")
						}
					}
				}
				out, err := m.Call(context.Background(), tc.shared, json.RawMessage(`{}`))
				if tc.loader {
					if err == nil {
						t.Fatal("loader routed to a server tool")
					}
				} else if err != nil || out != "first" {
					t.Fatalf("route = %q, %v", out, err)
				}
			}
		})
	}
}
