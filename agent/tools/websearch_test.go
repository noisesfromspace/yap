package tools

import (
	"strings"
	"testing"
)

// stubProvider is a deterministic search backend for dispatch/formatting
// tests. The concrete Exa provider lives in agent/websearch/exa and is
// tested there.
type stubProvider struct {
	last    WebsearchParams
	results []WebsearchResult
	err     error
}

func (s *stubProvider) Search(p WebsearchParams) ([]WebsearchResult, error) {
	s.last = p
	return s.results, s.err
}

func TestWebsearchFormatting(t *testing.T) {
	sp := &stubProvider{results: []WebsearchResult{
		{Title: "T1", URL: "https://a", Snippet: "S1"},
		{URL: "https://b", Snippet: "multi\nline"},
	}}
	RegisterWebsearchProvider("stub", sp)
	defer delete(websearchProviders, "stub")

	old := websearchProviderName
	websearchProviderName = "stub"
	defer func() { websearchProviderName = old }()

	r, _, err := run(t, "websearch", `{"query":"hello"}`)
	if err != nil {
		t.Fatalf("websearch: %v", err)
	}
	for _, want := range []string{
		"## Search: hello",
		"### 1. T1",
		"- **URL:** https://a",
		"- S1",
		"### 2. https://b",
		"- **URL:** https://b",
		"multi\nline",
	} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q in %q", want, r)
		}
	}
	// the dispatcher applies the default limit before the provider sees it
	if sp.last.Query != "hello" || sp.last.Limit != websearchLimitDefault {
		t.Fatalf("params: %+v", sp.last)
	}
}

func TestWebsearchProviderSelection(t *testing.T) {
	RegisterWebsearchProvider("stub", &stubProvider{results: []WebsearchResult{
		{Title: "Stub Title", URL: "https://stub", Snippet: "Stub Snippet"},
	}})
	defer delete(websearchProviders, "stub")

	old := websearchProviderName
	websearchProviderName = "stub"
	defer func() { websearchProviderName = old }()

	r, _, err := run(t, "websearch", `{"query":"hello"}`)
	if err != nil {
		t.Fatalf("websearch stub: %v", err)
	}
	for _, want := range []string{"## Search: hello", "### 1. Stub Title", "- **URL:** https://stub", "- Stub Snippet"} {
		if !strings.Contains(r, want) {
			t.Fatalf("missing %q in %q", want, r)
		}
	}

	websearchProviderName = "nope"
	if _, _, err := run(t, "websearch", `{"query":"x"}`); err == nil || !strings.Contains(err.Error(), "nope") {
		t.Fatalf("unknown provider: %v", err)
	}
}
