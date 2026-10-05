package tools

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"strings"
	"time"

	"boers.email/yap/agent/utils"
)

var githubAPI = "https://api.github.com" // replaced with a local server in tests
var githubAPIKeyEnv = "GITHUB_TOKEN"

// SetGitHubAPIKeyEnv configures the name, never the value, of the token variable.
func SetGitHubAPIKeyEnv(name string) {
	if name == "" {
		name = "GITHUB_TOKEN"
	}
	githubAPIKeyEnv = name
}

type githubArgs struct {
	Action string `json:"action" jsonschema:"description=GitHub read operation,enum=search_code,enum=search_issues,enum=search_repos,enum=read_file,enum=read_issue,enum=read_pr,enum=list_projects,enum=read_project"`
	Query  string `json:"query,omitempty" jsonschema:"description=GitHub search query (supports repo: owner: is:pr etc); for list_projects optional title filter"`
	Owner  string `json:"owner,omitempty" jsonschema:"description=repository or project owner"`
	Repo   string `json:"repo,omitempty" jsonschema:"description=repository name"`
	Number int    `json:"number,omitempty" jsonschema:"description=issue PR or project number"`
	Path   string `json:"path,omitempty" jsonschema:"description=path within repository for read_file"`
	Ref    string `json:"ref,omitempty" jsonschema:"description=branch tag or commit for read_file (default repository default branch)"`
	Page   int    `json:"page,omitempty" jsonschema:"description=REST search page (default 1; max 10)"`
	Cursor string `json:"cursor,omitempty" jsonschema:"description=GraphQL cursor for project list or items"`
	Safety bool   `json:"safety,omitempty" jsonschema:"description=run an optional jev prompt-injection check on untrusted GitHub content"`
}

func init() {
	Register("github", "Search and read GitHub (read-only). Use this instead of curl, fetch, websearch or gh for GitHub code, repositories, issues, PRs, files and Projects v2. Search queries accept GitHub qualifiers. Results are bounded; pass page or cursor for more. Uses the configured token environment variable when set; public REST reads also work without one (with lower rate limits). Projects v2 may require a token.", func(a *githubArgs) (string, string, error) { return runGitHub(a) })
}

const githubMaxBody = 512 * 1024
const githubMaxOutput = 50 * 1024

func githubRequest(method, endpoint string, payload []byte) ([]byte, error) {
	req, err := http.NewRequest(method, githubAPI+endpoint, bytes.NewReader(payload))
	if err != nil {
		return nil, err
	}
	if key := os.Getenv(githubAPIKeyEnv); key != "" {
		req.Header.Set("Authorization", "Bearer "+key)
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	if strings.HasPrefix(endpoint, "/search/code?") {
		req.Header.Set("Accept", "application/vnd.github.text-match+json")
	}
	req.Header.Set("X-GitHub-Api-Version", "2022-11-28")
	if payload != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{Timeout: 20 * time.Second, CheckRedirect: func(*http.Request, []*http.Request) error { return http.ErrUseLastResponse }}
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	body, err := io.ReadAll(io.LimitReader(resp.Body, githubMaxBody+1))
	if err != nil {
		return nil, err
	}
	if len(body) > githubMaxBody {
		return nil, fmt.Errorf("GitHub response exceeds %d bytes", githubMaxBody)
	}
	if resp.StatusCode < 200 || resp.StatusCode >= 300 {
		var e struct {
			Message string `json:"message"`
		}
		_ = json.Unmarshal(body, &e)
		if e.Message == "" {
			e.Message = resp.Status
		}
		return nil, fmt.Errorf("GitHub API %s: %s", resp.Status, e.Message)
	}
	return body, nil
}

func githubJSON(endpoint string) (any, error) {
	b, err := githubRequest(http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	var v any
	if err := json.Unmarshal(b, &v); err != nil {
		return nil, err
	}
	return v, nil
}

// Only retain fields the model can use; don't dump full API objects into context.
func githubFields(v any, keys ...string) map[string]any {
	m, _ := v.(map[string]any)
	out := map[string]any{}
	for _, k := range keys {
		if value, ok := m[k]; ok {
			out[k] = value
		}
	}
	return out
}

func githubItems(v any, keys ...string) []any {
	list, _ := v.([]any)
	out := make([]any, 0, len(list))
	for _, item := range list {
		out = append(out, githubFields(item, keys...))
	}
	return out
}

func githubSegment(s string) string { return url.PathEscape(s) }
func githubRepo(a *githubArgs) (string, error) {
	if strings.TrimSpace(a.Owner) == "" || strings.TrimSpace(a.Repo) == "" || strings.Contains(a.Owner, "/") || strings.Contains(a.Repo, "/") {
		return "", fmt.Errorf("owner and repo are required (without slashes)")
	}
	return "/repos/" + githubSegment(a.Owner) + "/" + githubSegment(a.Repo), nil
}

const githubProjectsQuery = `query($owner:String!, $number:Int!, $cursor:String, $filter:String!) {
 repositoryOwner(login:$owner) {
  ... on Organization { projectV2(number:$number) { ...ProjectDetails } }
  ... on User { projectV2(number:$number) { ...ProjectDetails } }
 }
}
fragment ProjectDetails on ProjectV2 { number title url shortDescription items(first:20, after:$cursor, query:$filter) { pageInfo { hasNextPage endCursor } nodes { id type content { ... on Issue { number title url state } ... on PullRequest { number title url state } ... on DraftIssue { title } } } } }`

const githubListProjectsQuery = `query($owner:String!, $cursor:String) {
 repositoryOwner(login:$owner) {
  ... on Organization { projectsV2(first:20, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { number title url shortDescription } } }
  ... on User { projectsV2(first:20, after:$cursor) { pageInfo { hasNextPage endCursor } nodes { number title url shortDescription } } }
 }
}`

func githubGraphQL(query string, vars map[string]any) (any, error) {
	payload, err := json.Marshal(map[string]any{"query": query, "variables": vars})
	if err != nil {
		return nil, err
	}
	b, err := githubRequest(http.MethodPost, "/graphql", payload)
	if err != nil {
		return nil, err
	}
	var result struct {
		Data   any `json:"data"`
		Errors []struct {
			Message string `json:"message"`
		} `json:"errors"`
	}
	if err := json.Unmarshal(b, &result); err != nil {
		return nil, err
	}
	if len(result.Errors) != 0 {
		return nil, fmt.Errorf("GitHub GraphQL: %s", result.Errors[0].Message)
	}
	owner := githubFields(result.Data, "repositoryOwner")["repositoryOwner"]
	if owner == nil {
		return nil, fmt.Errorf("GitHub owner not found or inaccessible")
	}
	return owner, nil
}

func runGitHub(a *githubArgs) (string, string, error) {
	var result any
	var err error
	switch a.Action {
	case "search_code", "search_issues", "search_repos":
		if strings.TrimSpace(a.Query) == "" {
			return "", "", fmt.Errorf("query is required")
		}
		page := a.Page
		if page == 0 {
			page = 1
		}
		if page < 1 || page > 10 {
			return "", "", fmt.Errorf("page must be 1..10")
		}
		kind := map[string]string{"search_code": "code", "search_issues": "issues", "search_repos": "repositories"}[a.Action]
		var data any
		data, err = githubJSON("/search/" + kind + "?q=" + url.QueryEscape(a.Query) + "&per_page=20&page=" + strconv.Itoa(page))
		if err == nil {
			m := githubFields(data, "total_count", "incomplete_results")
			items := githubFields(data, "items")["items"]
			switch a.Action {
			case "search_code":
				matches := githubItems(items, "name", "path", "html_url", "text_matches")
				original, _ := items.([]any)
				for i, item := range original {
					matches[i].(map[string]any)["repository"] = githubFields(githubFields(item, "repository")["repository"], "full_name", "html_url")
				}
				m["items"] = matches
			case "search_issues":
				m["items"] = githubItems(items, "number", "title", "html_url", "state", "updated_at", "pull_request")
			case "search_repos":
				m["items"] = githubItems(items, "full_name", "html_url", "description", "language", "stargazers_count")
			}
			result = m
		}
	case "read_file":
		var base string
		base, err = githubRepo(a)
		if err != nil {
			break
		}
		if strings.TrimSpace(a.Path) == "" || strings.HasPrefix(a.Path, "/") || strings.Contains(a.Path, "\\") {
			err = fmt.Errorf("path must be a relative file path")
			break
		}
		parts := strings.Split(a.Path, "/")
		for i, part := range parts {
			if part == "" || part == "." || part == ".." {
				err = fmt.Errorf("invalid file path")
				break
			}
			parts[i] = githubSegment(part)
		}
		if err != nil {
			break
		}
		endpoint := base + "/contents/" + strings.Join(parts, "/")
		if a.Ref != "" {
			endpoint += "?ref=" + url.QueryEscape(a.Ref)
		}
		var data any
		data, err = githubJSON(endpoint)
		if err != nil {
			break
		}
		m := githubFields(data, "path", "html_url", "sha", "size", "encoding", "content")
		if m["encoding"] != "base64" {
			err = fmt.Errorf("GitHub did not return base64 file content (file too large or not a file)")
			break
		}
		encoded, _ := m["content"].(string)
		var content []byte
		content, err = base64.StdEncoding.DecodeString(strings.ReplaceAll(encoded, "\n", ""))
		if err != nil {
			break
		}
		if bytes.IndexByte(content, 0) >= 0 {
			err = fmt.Errorf("binary file cannot be shown as text")
			break
		}
		delete(m, "encoding")
		m["content"] = string(content)
		result = m
	case "read_issue", "read_pr":
		var base string
		base, err = githubRepo(a)
		if err != nil {
			break
		}
		if a.Number <= 0 {
			err = fmt.Errorf("number must be positive")
			break
		}
		n := strconv.Itoa(a.Number)
		endpoint := base + "/issues/" + n
		if a.Action == "read_pr" {
			endpoint = base + "/pulls/" + n
		}
		var data, comments any
		data, err = githubJSON(endpoint)
		if err != nil {
			break
		}
		m := githubFields(data, "number", "title", "html_url", "state", "body", "created_at", "updated_at", "closed_at", "merged_at", "draft", "diff_url", "commits", "additions", "deletions", "changed_files")
		if a.Action == "read_issue" {
			if githubFields(data, "pull_request")["pull_request"] != nil {
				err = fmt.Errorf("number refers to a pull request; use read_pr")
				break
			}
		}
		comments, err = githubJSON(base + "/issues/" + n + "/comments?per_page=20")
		if err != nil {
			break
		}
		m["comments"] = githubItems(comments, "html_url", "body", "created_at", "user")
		for _, c := range m["comments"].([]any) {
			cm := c.(map[string]any)
			cm["user"] = githubFields(cm["user"], "login")
		}
		if a.Action == "read_pr" {
			var files, reviews, reviewComments any
			files, err = githubJSON(base + "/pulls/" + n + "/files?per_page=20")
			if err != nil {
				break
			}
			reviews, err = githubJSON(base + "/pulls/" + n + "/reviews?per_page=20")
			if err != nil {
				break
			}
			reviewComments, err = githubJSON(base + "/pulls/" + n + "/comments?per_page=20")
			if err != nil {
				break
			}
			m["files"] = githubItems(files, "filename", "status", "additions", "deletions", "patch")
			m["reviews"] = githubItems(reviews, "body", "state", "html_url", "user")
			for _, r := range m["reviews"].([]any) {
				rm := r.(map[string]any)
				rm["user"] = githubFields(rm["user"], "login")
			}
			m["review_comments"] = githubItems(reviewComments, "path", "line", "body", "html_url", "user")
			for _, c := range m["review_comments"].([]any) {
				cm := c.(map[string]any)
				cm["user"] = githubFields(cm["user"], "login")
			}
		}
		result = m
	case "list_projects", "read_project":
		if strings.TrimSpace(a.Owner) == "" || strings.Contains(a.Owner, "/") {
			return "", "", fmt.Errorf("owner is required (without slashes)")
		}
		vars := map[string]any{"owner": a.Owner, "cursor": nil}
		if a.Cursor != "" {
			vars["cursor"] = a.Cursor
		}
		if a.Action == "list_projects" {
			result, err = githubGraphQL(githubListProjectsQuery, vars)
			if err == nil && a.Query != "" { // title filter is local to the current page
				projects := githubFields(result, "projectsV2")["projectsV2"]
				list := githubFields(projects, "nodes")["nodes"]
				filtered := []any{}
				for _, p := range githubItems(list, "number", "title", "url", "shortDescription") {
					title, _ := p.(map[string]any)["title"].(string)
					if strings.Contains(strings.ToLower(title), strings.ToLower(a.Query)) {
						filtered = append(filtered, p)
					}
				}
				result = map[string]any{"projects": filtered, "pageInfo": githubFields(projects, "pageInfo")["pageInfo"]}
			}
		} else {
			if a.Number <= 0 {
				return "", "", fmt.Errorf("number must be positive")
			}
			vars["number"] = a.Number
			vars["filter"] = a.Query
			result, err = githubGraphQL(githubProjectsQuery, vars)
			if err == nil {
				result = githubFields(result, "projectV2")["projectV2"]
				if result == nil {
					err = fmt.Errorf("project not found or inaccessible")
				}
			}
		}
	default:
		return "", "", fmt.Errorf("unknown GitHub action %q", a.Action)
	}
	if err != nil {
		return "", "", err
	}
	b, err := json.MarshalIndent(result, "", "  ")
	if err != nil {
		return "", "", err
	}
	text := string(b)
	if len(text) > githubMaxOutput {
		text = text[:githubMaxOutput] + "\n[truncated; narrow the query or read a smaller file]"
	}
	return utils.SafetyGuarded(decisionModel, a.Safety, text), "", nil
}
