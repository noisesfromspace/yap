package exa

import (
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"boers.email/yap/agent/tools"
)

func TestSearchRequest(t *testing.T) {
	var gotKey, gotPath string
	var body map[string]any

	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		gotKey = r.Header.Get("x-api-key")
		gotPath = r.URL.Path
		json.NewDecoder(r.Body).Decode(&body)
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"results":[{"title":"T1","url":"https://a","summary":"S1"}]}`)
	}))
	defer srv.Close()

	oldEndpoint, oldEnv := endpoint, apiKeyEnv
	endpoint, apiKeyEnv = srv.URL+"/search", "YAP_TEST_EXA_KEY"
	defer func() { endpoint, apiKeyEnv = oldEndpoint, oldEnv }()
	t.Setenv("YAP_TEST_EXA_KEY", "sekret")

	res, err := (provider{}).Search(tools.WebsearchParams{Query: "hello", Limit: 8, Type: "fast", ContentMode: "summary"})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(res) != 1 || res[0].Title != "T1" || res[0].URL != "https://a" || res[0].Snippet != "S1" {
		t.Fatalf("results: %+v", res)
	}
	if gotKey != "sekret" || gotPath != "/search" {
		t.Fatalf("request key/path: %q %q", gotKey, gotPath)
	}
	if body["query"] != "hello" || body["type"] != "fast" || body["numResults"] != float64(8) {
		t.Fatalf("body: %v", body)
	}
	contents, _ := body["contents"].(map[string]any)
	if contents["summary"] != true {
		t.Fatalf("contents: %v", body["contents"])
	}
}

func TestSearchMissingKey(t *testing.T) {
	oldEnv := apiKeyEnv
	apiKeyEnv = "YAP_TEST_EXA_KEY"
	defer func() { apiKeyEnv = oldEnv }()
	t.Setenv("YAP_TEST_EXA_KEY", "")

	if _, err := (provider{}).Search(tools.WebsearchParams{Query: "x", Limit: 8}); err == nil || !strings.Contains(err.Error(), "YAP_TEST_EXA_KEY") {
		t.Fatalf("missing key: %v", err)
	}
}

func TestSearchHighlights(t *testing.T) {
	// Highlights (the default content mode) are returned joined; an empty
	// title is left empty — the dispatcher falls back to the URL when
	// rendering.
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		io.WriteString(w, `{"results":[{"title":"","url":"https://a","highlights":["hl one","hl two"]}]}`)
	}))
	defer srv.Close()

	old := endpoint
	endpoint = srv.URL
	defer func() { endpoint = old }()
	t.Setenv(apiKeyEnv, "sekret")

	res, err := (provider{}).Search(tools.WebsearchParams{Query: "hello", Limit: 8})
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if len(res) != 1 || res[0].Title != "" || res[0].Snippet != "hl one\nhl two" {
		t.Fatalf("results: %+v", res)
	}
}

func TestSearchContentModeError(t *testing.T) {
	if _, err := (provider{}).Search(tools.WebsearchParams{Query: "x", Limit: 8, ContentMode: "bogus"}); err == nil || !strings.Contains(err.Error(), "contentMode") {
		t.Fatalf("contentMode: %v", err)
	}
}
