package tools

import (
	"fmt"
	"strings"
)

// Websearch is a thin dispatcher over pluggable search providers. Each
// provider lives outside this package (e.g. agent/websearch/exa) and
// self-registers via RegisterWebsearchProvider in init(). The active
// provider is selected per turn by SetWebsearchProvider (default "exa",
// from config).

const (
	websearchLimitDefault = 8
	websearchLimitMax     = 25
)

// WebsearchParams is the provider-facing subset of the tool's args. The
// dispatcher maps the full tool args onto this shape, so a provider need
// know nothing about the tool's JSON schema or guard rules.
type WebsearchParams struct {
	Query          string
	Limit          int
	Type           string
	ContentMode    string
	IncludeDomains []string
	ExcludeDomains []string
	MaxAgeHours    *int
}

// WebsearchProvider is one search backend. It maps the common tool args
// onto its own API and returns results normalized to WebsearchResult;
// provider-specific args are ignored (or mapped) by the provider itself.
type WebsearchProvider interface {
	Search(p WebsearchParams) ([]WebsearchResult, error)
}

// WebsearchResult is the normalized shape shared by all providers.
type WebsearchResult struct {
	Title   string
	URL     string
	Snippet string
}

var websearchProviders = map[string]WebsearchProvider{}

// RegisterWebsearchProvider adds a search backend; called from the
// provider package's init().
func RegisterWebsearchProvider(name string, p WebsearchProvider) {
	websearchProviders[name] = p
}

// websearchProviderName selects the active provider; config overrides it.
var websearchProviderName = "exa"

// SetWebsearchProvider overrides the active provider name from config.
func SetWebsearchProvider(name string) {
	if name != "" {
		websearchProviderName = name
	}
}

type websearchArgs struct {
	Query          string   `json:"query" jsonschema:"description=the search query"`
	Limit          int      `json:"limit,omitempty" jsonschema:"description=max number of results (default 8; hard cap 25)"`
	Type           string   `json:"type,omitempty" jsonschema:"description=search type (default auto),enum=auto,enum=fast,enum=instant,enum=deep-lite,enum=deep,enum=deep-reasoning"`
	ContentMode    string   `json:"contentMode,omitempty" jsonschema:"description=content to return per result (default highlights),enum=highlights,enum=summary,enum=text"`
	IncludeDomains []string `json:"includeDomains,omitempty" jsonschema:"description=restrict results to these domains"`
	ExcludeDomains []string `json:"excludeDomains,omitempty" jsonschema:"description=exclude results from these domains"`
	MaxAgeHours    *int     `json:"maxAgeHours,omitempty" jsonschema:"description=max age of cached content in hours (0=livecrawl; -1=cache only)"`
}

func init() {
	Register("websearch",
		"Search the web. Returns up to N results with title, URL, and an excerpt. "+
			"Use type=deep for thorough research and type=fast for quick lookups.",
		func(a *websearchArgs) (string, string, error) { return runWebsearch(a) })
}

func runWebsearch(a *websearchArgs) (string, string, error) {
	if strings.TrimSpace(a.Query) == "" {
		return "", "", fmt.Errorf("empty query")
	}

	limit := a.Limit
	if limit <= 0 {
		limit = websearchLimitDefault
	}
	if limit > websearchLimitMax {
		limit = websearchLimitMax
	}
	a.Limit = limit

	p, ok := websearchProviders[websearchProviderName]
	if !ok {
		return "", "", fmt.Errorf("websearch provider %q is not registered", websearchProviderName)
	}

	results, err := p.Search(WebsearchParams{
		Query:          a.Query,
		Limit:          a.Limit,
		Type:           a.Type,
		ContentMode:    a.ContentMode,
		IncludeDomains: a.IncludeDomains,
		ExcludeDomains: a.ExcludeDomains,
		MaxAgeHours:    a.MaxAgeHours,
	})
	if err != nil {
		return "", "", err
	}
	// Providers are asked for `limit` results; trim anyway so a backend that
	// ignores numResults cannot flood the transcript.
	if len(results) > a.Limit {
		results = results[:a.Limit]
	}

	// Format as markdown — token-cheaper and easier for LLMs than JSON.
	var b strings.Builder
	fmt.Fprintf(&b, "## Search: %s\n", a.Query)
	if len(results) == 0 {
		b.WriteString("\n(no results found)")
	} else {
		for i, r := range results {
			title := r.Title
			if title == "" {
				title = r.URL
			}
			fmt.Fprintf(&b, "\n### %d. %s\n", i+1, title)
			fmt.Fprintf(&b, "- **URL:** %s\n", r.URL)
			if r.Snippet != "" {
				if strings.Contains(r.Snippet, "\n") {
					b.WriteString(r.Snippet)
					b.WriteString("\n")
				} else {
					fmt.Fprintf(&b, "- %s\n", r.Snippet)
				}
			}
		}
	}
	// Cap the assembled result: 25 results in contentMode=text can carry
	// hundreds of KB, and every byte of it lands in the transcript.
	out := b.String()
	if len(out) > readMaxBytes {
		out = capBytes(out, readMaxBytes) + "\n[truncated at 50KB: lower limit or use contentMode=highlights]"
	}
	return out, "", nil
}
