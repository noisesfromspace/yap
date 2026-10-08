package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"strings"
	"time"

	"boers.email/yap/agent/utils"

	readability "codeberg.org/readeck/go-readability/v2"
	htmltomarkdown "github.com/JohannesKaufmann/html-to-markdown/v2"
)

// fetchMaxBytes caps the text sent to the model; fetchMaxHTMLBytes bounds
// how much HTML we download to run readability extraction over.
const (
	fetchMaxBytes     = 50 * 1024
	fetchMaxHTMLBytes = 5 * 1024 * 1024
)

type fetchArgs struct {
	URL            string `json:"url" jsonschema:"description=http(s) URL to fetch"`
	Safety         bool   `json:"safety,omitempty" jsonschema:"description=when true, run a jev prompt-injection check on the result before returning it; flagged content is annotated with a warning (costs one extra decision-model call, so use only for untrusted content)"`
	IsolateNetwork bool   `json:"isolate_network,omitempty" jsonschema:"description=run the request in a private network namespace with no connectivity (Linux only; requires util-linux unshare)"`
}

func init() {
	Register("fetch",
		"Fetch a URL over HTTP(S) and return the main content as Markdown. "+
			"HTML pages are run through readability extraction (strips nav, sidebars, ads, scripts) and converted to Markdown; "+
			"non-HTML bodies (JSON, plain text, …) are returned as-is. Truncated to 50KB. "+
			"Use curl for raw HTML inspection.",
		func(a *fetchArgs) (string, string, error) {
			var (
				status                  int
				statusText, contentType string
				finalURL                *url.URL
				body                    []byte
				err                     error
			)
			if a.IsolateNetwork {
				status, statusText, contentType, finalURL, body, err = fetchIsolated(a.URL)
			} else {
				status, statusText, contentType, finalURL, body, err = fetchRaw(a.URL)
			}
			if err != nil {
				return "", "", err
			}
			return fetchProcess(status, statusText, contentType, finalURL, body, a.Safety)
		})
}

// fetchRaw performs one SSRF-checked GET (redirects followed; every hop is
// re-checked by CheckedTransport's dialer) and returns the response status
// and raw body, capped at the HTML limit. Readability extraction happens
// later, in fetchProcess, so this half can run in an isolated namespace.
func fetchRaw(rawURL string) (status int, statusText, contentType string, finalURL *url.URL, body []byte, err error) {
	if !strings.HasPrefix(rawURL, "http://") && !strings.HasPrefix(rawURL, "https://") {
		return 0, "", "", nil, nil, fmt.Errorf("only http(s) URLs supported")
	}

	client := &http.Client{Timeout: 30 * time.Second, Transport: utils.CheckedTransport()}
	resp, err := client.Get(rawURL)
	if err != nil {
		return 0, "", "", nil, nil, err
	}
	defer resp.Body.Close()
	body, err = io.ReadAll(io.LimitReader(resp.Body, int64(fetchMaxHTMLBytes)+1))
	if err != nil {
		return 0, "", "", nil, nil, err
	}
	finalURL = resp.Request.URL
	if finalURL == nil {
		finalURL, _ = url.Parse(rawURL)
	}
	return resp.StatusCode, resp.Status, resp.Header.Get("Content-Type"), finalURL, body, nil
}

// fetchProcess turns a fetched response into the tool result: readability
// extraction for HTML, capped text for everything else, and the optional
// prompt-injection scan.
func fetchProcess(status int, statusText, contentType string, finalURL *url.URL, body []byte, safety bool) (string, string, error) {
	if status != http.StatusOK {
		return fmt.Sprintf("error: %s", statusText), "", nil
	}
	if !isHTMLContentType(contentType) {
		return utils.SafetyGuarded(decisionModel, safety, capText(string(body))), "", nil
	}

	text, err := extractMarkdown(body, finalURL)
	if err != nil {
		// Extraction failed (e.g. the page is not an article): fall back to
		// converting the whole page, mirroring the old raw-HTML path but
		// still returning Markdown, not tags.
		if md, mdErr := htmltomarkdown.ConvertString(string(body)); mdErr == nil {
			return utils.SafetyGuarded(decisionModel, safety, capText(md)), "", nil
		}
		return "", "", err
	}
	return utils.SafetyGuarded(decisionModel, safety, capText(text)), "", nil
}

// fetchIsolated runs the GET in a private user+network namespace, so the
// request has no outbound or loopback connectivity: an exfiltration attempt
// fails closed instead of reaching a destination. The fetch half runs as the
// `yap fetch-worker` subcommand; this process only decodes its framed result.
func fetchIsolated(rawURL string) (status int, statusText, contentType string, finalURL *url.URL, body []byte, err error) {
	self, err := os.Executable()
	if err != nil {
		return 0, "", "", nil, nil, fmt.Errorf("isolated fetch: %w", err)
	}
	cmd := exec.Command("unshare", "--user", "--map-root-user", "--net", self, "fetch-worker", rawURL)
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		if s := strings.TrimSpace(stderr.String()); s != "" {
			return 0, "", "", nil, nil, fmt.Errorf("isolated fetch: %v: %s", err, s)
		}
		return 0, "", "", nil, nil, fmt.Errorf("isolated fetch: %w", err)
	}
	return parseFetchWorker(stdout.Bytes(), rawURL)
}

// fetchWorkerResult is the framed output of the fetch worker subprocess.
type fetchWorkerResult struct {
	Error       string `json:"error,omitempty"`
	Status      int    `json:"status,omitempty"`
	StatusText  string `json:"status_text,omitempty"`
	ContentType string `json:"content_type,omitempty"`
	FinalURL    string `json:"final_url,omitempty"`
	Body        []byte `json:"body,omitempty"`
}

// RunFetchWorker is the `yap fetch-worker URL` subcommand: one SSRF-checked
// GET, framed as fetchWorkerResult JSON on stdout for the parent fetch tool
// to decode. It runs inside the isolated network namespace.
func RunFetchWorker(rawURL string, out io.Writer) error {
	status, statusText, contentType, finalURL, body, err := fetchRaw(rawURL)
	res := fetchWorkerResult{}
	if err != nil {
		res.Error = err.Error()
	} else {
		res.Status = status
		res.StatusText = statusText
		res.ContentType = contentType
		if finalURL != nil {
			res.FinalURL = finalURL.String()
		}
		res.Body = body
	}
	return json.NewEncoder(out).Encode(res)
}

// parseFetchWorker decodes the worker's framed output into the same shape
// fetchRaw returns, so the isolate_network path shares fetchProcess.
func parseFetchWorker(data []byte, fallbackURL string) (status int, statusText, contentType string, finalURL *url.URL, body []byte, err error) {
	var res fetchWorkerResult
	if err := json.Unmarshal(data, &res); err != nil {
		return 0, "", "", nil, nil, fmt.Errorf("isolated fetch: bad worker output: %w", err)
	}
	if res.Error != "" {
		return 0, "", "", nil, nil, fmt.Errorf("%s", res.Error)
	}
	if res.FinalURL == "" {
		res.FinalURL = fallbackURL
	}
	u, err := url.Parse(res.FinalURL)
	if err != nil {
		return 0, "", "", nil, nil, fmt.Errorf("isolated fetch: bad final URL: %w", err)
	}
	return res.Status, res.StatusText, res.ContentType, u, res.Body, nil
}

func isHTMLContentType(contentType string) bool {
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	return mt == "text/html" || mt == "application/xhtml+xml"
}

func extractMarkdown(body []byte, pageURL *url.URL) (string, error) {
	article, err := readability.FromReader(bytes.NewReader(body), pageURL)
	if err != nil {
		return "", err
	}

	var html strings.Builder
	if err := article.RenderHTML(&html); err != nil {
		return "", err
	}
	content := strings.TrimSpace(html.String())
	if content == "" {
		return "", fmt.Errorf("no readable content")
	}

	md, err := htmltomarkdown.ConvertString(content)
	if err != nil {
		return "", err
	}
	md = strings.TrimSpace(md)
	if md == "" {
		return "", fmt.Errorf("empty markdown")
	}

	var out strings.Builder
	if title := strings.TrimSpace(article.Title()); title != "" {
		fmt.Fprintf(&out, "# %s\n\n", title)
	}
	if byline := strings.TrimSpace(article.Byline()); byline != "" {
		fmt.Fprintf(&out, "By %s\n\n", byline)
	}
	out.WriteString(md)
	return out.String(), nil
}

func capText(s string) string {
	if len(s) > fetchMaxBytes {
		return s[:fetchMaxBytes] + "\n[truncated at 50KB]"
	}
	return s
}
