package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"
)

// Exa websearch tool — a port of pi's Exa search extension
// (~/.pi/agent/extensions/search.ts). The API key is read from an env
// var at call time: websearchAPIKeyEnv names the variable (set from
// config via SetWebsearchAPIKeyEnv; the value itself comes from the
// agenix-secret env file sourced by the wrapper before exec).

const (
	websearchLimitDefault = 8
	websearchLimitMax     = 25
)

// websearchURL is the Exa endpoint. A var so tests can point it at a
// local server (same pattern as utils.eventOut).
var websearchURL = "https://api.exa.ai/search"

// websearchAPIKeyEnv names the env var holding the Exa API key.
var websearchAPIKeyEnv = "EXA_API_KEY"

// SetWebsearchAPIKeyEnv overrides the env var name from config.
func SetWebsearchAPIKeyEnv(name string) {
	if name != "" {
		websearchAPIKeyEnv = name
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
		"Search the web via Exa. Returns up to N results with title, URL, and an excerpt. "+
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

	searchType := a.Type
	if searchType == "" {
		searchType = "auto"
	}
	contentMode := a.ContentMode
	if contentMode == "" {
		contentMode = "highlights"
	}

	contents := map[string]any{}
	switch contentMode {
	case "highlights":
		contents["highlights"] = true
	case "summary":
		contents["summary"] = true
	case "text":
		contents["text"] = map[string]int{"maxCharacters": 10000}
	default:
		return "", "", fmt.Errorf("contentMode must be one of highlights, summary, text")
	}

	body := map[string]any{
		"query":      a.Query,
		"type":       searchType,
		"numResults": limit,
		"contents":   contents,
	}
	if len(a.IncludeDomains) > 0 {
		body["includeDomains"] = a.IncludeDomains
	}
	if len(a.ExcludeDomains) > 0 {
		body["excludeDomains"] = a.ExcludeDomains
	}
	if a.MaxAgeHours != nil && *a.MaxAgeHours >= -1 {
		body["maxAgeHours"] = *a.MaxAgeHours
	}

	apiKey := os.Getenv(websearchAPIKeyEnv)
	if apiKey == "" {
		return "", "", fmt.Errorf("env var %s is not set", websearchAPIKeyEnv)
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return "", "", err
	}
	req, err := http.NewRequest(http.MethodPost, websearchURL, bytes.NewReader(payload))
	if err != nil {
		return "", "", err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", apiKey)

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return "", "", err
	}
	defer resp.Body.Close()

	var data struct {
		Results []struct {
			Title      string   `json:"title"`
			URL        string   `json:"url"`
			Summary    string   `json:"summary"`
			Highlights []string `json:"highlights"`
			Text       string   `json:"text"`
		} `json:"results"`
	}
	if resp.StatusCode != http.StatusOK {
		var e struct {
			Detail  string `json:"detail"`
			Message string `json:"message"`
		}
		json.NewDecoder(resp.Body).Decode(&e)
		msg := strings.TrimSpace(strings.TrimSpace(e.Detail) + " " + strings.TrimSpace(e.Message))
		if msg == "" {
			msg = resp.Status
		}
		return "", "", fmt.Errorf("Exa API error %s: %s", resp.Status, msg)
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return "", "", err
	}

	// Format as markdown — token-cheaper and easier for LLMs than JSON.
	var b strings.Builder
	fmt.Fprintf(&b, "## Search: %s\n", a.Query)
	if len(data.Results) == 0 {
		b.WriteString("\n(no results found)")
	} else {
		for i, r := range data.Results {
			title := r.Title
			if title == "" {
				title = r.URL
			}
			fmt.Fprintf(&b, "\n### %d. %s\n", i+1, title)
			fmt.Fprintf(&b, "- **URL:** %s\n", r.URL)
			switch {
			case len(r.Highlights) > 0:
				b.WriteString(strings.Join(r.Highlights, "\n"))
				b.WriteString("\n")
			case r.Summary != "":
				fmt.Fprintf(&b, "- %s\n", r.Summary)
			case r.Text != "":
				b.WriteString(r.Text)
				b.WriteString("\n")
			}
		}
	}
	return b.String(), "", nil
}
