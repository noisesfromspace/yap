package tools

import (
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestGitHub(t *testing.T) {
	var paths []string
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer test-token" {
			t.Errorf("missing auth")
		}
		paths = append(paths, r.URL.RequestURI())
		w.Header().Set("Content-Type", "application/json")
		switch r.URL.Path {
		case "/search/code":
			if r.Header.Get("Accept") != "application/vnd.github.text-match+json" {
				t.Errorf("code search missing text-match header")
			}
			fmt.Fprint(w, `{"total_count":1,"incomplete_results":false,"items":[{"path":"a.go","html_url":"https://github.com/o/r/blob/main/a.go","repository":{"full_name":"o/r","secret":"omit"}}]}`)
		case "/search/issues":
			fmt.Fprint(w, `{"total_count":1,"items":[{"number":7,"title":"bug","pull_request":{"url":"pr"}}]}`)
		case "/search/repositories":
			fmt.Fprint(w, `{"items":[{"full_name":"o/r","description":"project"}]}`)
		case "/repos/o/r/contents/dir/a.go":
			fmt.Fprint(w, `{"path":"dir/a.go","encoding":"base64","content":"aGVsbG8K","html_url":"https://github.com/o/r/blob/main/dir/a.go"}`)
		case "/repos/o/r/issues/7":
			fmt.Fprint(w, `{"number":7,"title":"issue","body":"body"}`)
		case "/repos/o/r/issues/7/comments":
			fmt.Fprint(w, `[{"body":"issue comment","user":{"login":"person","secret":"omit"}}]`)
		case "/repos/o/r/pulls/7":
			fmt.Fprint(w, `{"number":7,"title":"PR","body":"details"}`)
		case "/repos/o/r/pulls/7/files":
			fmt.Fprint(w, `[{"filename":"a.go","patch":"@@ -1 +1 @@"}]`)
		case "/repos/o/r/pulls/7/reviews":
			fmt.Fprint(w, `[{"body":"LGTM","state":"APPROVED"}]`)
		case "/repos/o/r/pulls/7/comments":
			fmt.Fprint(w, `[{"path":"a.go","body":"review comment"}]`)
		default:
			t.Errorf("unexpected path %q", r.URL.Path)
			w.WriteHeader(404)
		}
	}))
	defer srv.Close()
	oldURL, oldEnv := githubAPI, githubAPIKeyEnv
	githubAPI = srv.URL
	SetGitHubAPIKeyEnv("TEST_GITHUB_TOKEN")
	defer func() { githubAPI, githubAPIKeyEnv = oldURL, oldEnv }()
	t.Setenv("TEST_GITHUB_TOKEN", "test-token")
	for _, tc := range []struct{ args, want string }{
		{`{"action":"search_code","query":"hello repo:o/r","page":2}`, `"full_name": "o/r"`},
		{`{"action":"search_issues","query":"is:pr bug"}`, `"title": "bug"`},
		{`{"action":"search_repos","query":"topic:tools"}`, `"description": "project"`},
		{`{"action":"read_file","owner":"o","repo":"r","path":"dir/a.go","ref":"main"}`, `"content": "hello\n"`},
		{`{"action":"read_issue","owner":"o","repo":"r","number":7}`, `issue comment`},
		{`{"action":"read_pr","owner":"o","repo":"r","number":7}`, `review comment`},
	} {
		result, _, err := run(t, "github", tc.args)
		if err != nil || !strings.Contains(result, tc.want) || strings.Contains(result, "secret") {
			t.Errorf("%s: %v %s", tc.args, err, result)
		}
	}
	if !strings.Contains(paths[0], "q=hello+repo%3Ao%2Fr&per_page=20&page=2") || !strings.Contains(strings.Join(paths, " "), "ref=main") {
		t.Errorf("query or ref missing: %v", paths)
	}
}

func TestGitHubAnonymous(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if got := r.Header.Get("Authorization"); got != "" {
			t.Errorf("unexpected authorization header: %q", got)
		}
		fmt.Fprint(w, `{"items":[{"full_name":"o/r"}]}`)
	}))
	defer srv.Close()
	oldURL, oldEnv := githubAPI, githubAPIKeyEnv
	githubAPI = srv.URL
	defer func() { githubAPI, githubAPIKeyEnv = oldURL, oldEnv }()
	// Anonymous requests should work both with the default env name and a configured one.
	for _, name := range []string{"GITHUB_TOKEN", "TEST_GITHUB_TOKEN"} {
		SetGitHubAPIKeyEnv(name)
		t.Setenv(name, "")
		result, _, err := run(t, "github", `{"action":"search_repos","query":"tools"}`)
		if err != nil || !strings.Contains(result, `"full_name": "o/r"`) {
			t.Errorf("anonymous request (%s): %v %s", name, err, result)
		}
	}
}

func TestGitHubValidationAndErrors(t *testing.T) {
	for _, args := range []string{`{"action":"search_code"}`, `{"action":"read_file","owner":"o","repo":"r","path":"../bad"}`, `{"action":"read_pr","owner":"o","repo":"r","number":0}`, `{"action":"list_projects","owner":"o"}`, `{"action":"search_code","query":"x","page":11}`} {
		if _, _, err := run(t, "github", args); err == nil {
			t.Errorf("accepted %s", args)
		}
	}
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(403)
		fmt.Fprint(w, `{"message":"rate limit exceeded"}`)
	}))
	defer srv.Close()
	old := githubAPI
	githubAPI = srv.URL
	defer func() { githubAPI = old }()
	t.Setenv(githubAPIKeyEnv, "test-token")
	if _, _, err := run(t, "github", `{"action":"search_code","query":"x"}`); err == nil || !strings.Contains(err.Error(), "rate limit exceeded") {
		t.Errorf("API error: %v", err)
	}
}
