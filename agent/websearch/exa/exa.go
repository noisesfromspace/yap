// Package exa implements the Exa websearch provider for the websearch
// tool — a port of pi's Exa search extension
// (~/.pi/agent/extensions/search.ts). The API key is read from an env var
// at call time; SetAPIKeyEnv names the variable (set from config), and the
// key VALUE itself lives in the agenix-secret env file sourced by the
// wrapper before exec.
package exa

import (
	"bytes"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"strings"
	"time"

	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/utils"
)

// endpoint is the Exa API URL. A var so tests can point it at a local
// server.
var endpoint = "https://api.exa.ai/search"

// apiKeyEnv names the env var holding the Exa API key.
var apiKeyEnv = "EXA_API_KEY"

// SetEndpoint overrides the API endpoint (tests).
func SetEndpoint(url string) { endpoint = url }

// SetAPIKeyEnv overrides the env var name from config.
func SetAPIKeyEnv(name string) {
	if name != "" {
		apiKeyEnv = name
	}
}

type provider struct{}

func init() {
	tools.RegisterWebsearchProvider("exa", provider{})
}

func (provider) Search(p tools.WebsearchParams) ([]tools.WebsearchResult, error) {
	searchType := p.Type
	if searchType == "" {
		searchType = "auto"
	}
	contentMode := p.ContentMode
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
		return nil, fmt.Errorf("contentMode must be one of highlights, summary, text")
	}

	body := map[string]any{
		"query":      p.Query,
		"type":       searchType,
		"numResults": p.Limit,
		"contents":   contents,
	}
	if len(p.IncludeDomains) > 0 {
		body["includeDomains"] = p.IncludeDomains
	}
	if len(p.ExcludeDomains) > 0 {
		body["excludeDomains"] = p.ExcludeDomains
	}
	if p.MaxAgeHours != nil && *p.MaxAgeHours >= -1 {
		body["maxAgeHours"] = *p.MaxAgeHours
	}

	apiKey := os.Getenv(apiKeyEnv)
	if apiKey == "" {
		return nil, fmt.Errorf("env var %s is not set", apiKeyEnv)
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequestWithContext(utils.TurnContext(), http.MethodPost, endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("x-api-key", apiKey)

	client := &http.Client{Timeout: 15 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // best-effort: close on read

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
		_ = json.NewDecoder(resp.Body).Decode(&e)
		msg := strings.TrimSpace(strings.TrimSpace(e.Detail) + " " + strings.TrimSpace(e.Message))
		if msg == "" {
			msg = resp.Status
		}
		return nil, fmt.Errorf("exa API error %s: %s", resp.Status, msg)
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}

	results := make([]tools.WebsearchResult, 0, len(data.Results))
	for _, r := range data.Results {
		snippet := ""
		switch {
		case len(r.Highlights) > 0:
			snippet = strings.Join(r.Highlights, "\n")
		case r.Summary != "":
			snippet = r.Summary
		case r.Text != "":
			snippet = r.Text
		}
		results = append(results, tools.WebsearchResult{Title: r.Title, URL: r.URL, Snippet: snippet})
	}
	return results, nil
}
