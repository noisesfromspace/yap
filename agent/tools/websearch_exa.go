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

// Exa search provider — a port of pi's Exa search extension
// (~/.pi/agent/extensions/search.ts). The API key is read from an env
// var at call time: exaAPIKeyEnv names the variable (set from config via
// SetWebsearchAPIKeyEnv; the value itself comes from the agenix-secret
// env file sourced by the wrapper before exec).

// exaURL is the Exa endpoint. A var so tests can point it at a local
// server (same pattern as utils.eventOut).
var exaURL = "https://api.exa.ai/search"

// exaAPIKeyEnv names the env var holding the Exa API key.
var exaAPIKeyEnv = "EXA_API_KEY"

// SetWebsearchAPIKeyEnv overrides the env var name from config.
func SetWebsearchAPIKeyEnv(name string) {
	if name != "" {
		exaAPIKeyEnv = name
	}
}

type exaProvider struct{}

func init() {
	registerWebsearchProvider("exa", exaProvider{})
}

func (exaProvider) search(a *websearchArgs) ([]websearchResult, error) {
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
		return nil, fmt.Errorf("contentMode must be one of highlights, summary, text")
	}

	body := map[string]any{
		"query":      a.Query,
		"type":       searchType,
		"numResults": a.Limit,
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

	apiKey := os.Getenv(exaAPIKeyEnv)
	if apiKey == "" {
		return nil, fmt.Errorf("env var %s is not set", exaAPIKeyEnv)
	}

	payload, err := json.Marshal(body)
	if err != nil {
		return nil, err
	}
	req, err := http.NewRequest(http.MethodPost, exaURL, bytes.NewReader(payload))
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
		return nil, fmt.Errorf("exa API error %s: %s", resp.Status, msg)
	}
	if err := json.NewDecoder(resp.Body).Decode(&data); err != nil {
		return nil, err
	}

	results := make([]websearchResult, 0, len(data.Results))
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
		results = append(results, websearchResult{Title: r.Title, URL: r.URL, Snippet: snippet})
	}
	return results, nil
}
