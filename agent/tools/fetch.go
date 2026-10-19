package tools

import (
	"bytes"
	"fmt"
	"io"
	"mime"
	"net/http"
	"net/url"
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
	URL string `json:"url" jsonschema:"description=http(s) URL to fetch"`
}

func init() {
	Register("fetch",
		"Fetch a URL over HTTP(S) and return the main content as Markdown. "+
			"HTML pages are run through readability extraction (strips nav, sidebars, ads, scripts) and converted to Markdown; "+
			"non-HTML bodies (JSON, plain text, …) are returned as-is. Truncated to 50KB. "+
			"Use curl for raw HTML inspection.",
		func(a *fetchArgs) (string, string, error) {
			status, statusText, contentType, finalURL, body, err := fetchRaw(a.URL)
			if err != nil {
				return "", "", err
			}
			return fetchProcess(status, statusText, contentType, finalURL, body)
		})
}

// fetchRaw performs one SSRF-checked GET (redirects followed; every hop is
// re-checked by CheckedTransport's dialer) and returns the response status
// and raw body, capped at the HTML limit. Readability extraction happens
// later, in fetchProcess.
func fetchRaw(rawURL string) (status int, statusText, contentType string, finalURL *url.URL, body []byte, err error) {
	if !strings.HasPrefix(rawURL, "http://") && !strings.HasPrefix(rawURL, "https://") {
		return 0, "", "", nil, nil, fmt.Errorf("only http(s) URLs supported")
	}

	client := &http.Client{Timeout: 30 * time.Second, Transport: utils.CheckedTransport()}
	resp, err := client.Get(rawURL)
	if err != nil {
		return 0, "", "", nil, nil, err
	}
	defer resp.Body.Close() //nolint:errcheck // best-effort: close on read
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
// extraction for HTML, capped text for everything else.
func fetchProcess(status int, statusText, contentType string, finalURL *url.URL, body []byte) (string, string, error) {
	if status != http.StatusOK {
		return fmt.Sprintf("error: %s", statusText), "", nil
	}
	if !isHTMLContentType(contentType) {
		return capText(string(body)), "", nil
	}

	text, err := extractMarkdown(body, finalURL)
	if err != nil {
		// Extraction failed (e.g. the page is not an article): fall back to
		// converting the whole page, mirroring the old raw-HTML path but
		// still returning Markdown, not tags.
		if md, mdErr := htmltomarkdown.ConvertString(string(body)); mdErr == nil {
			return capText(md), "", nil
		}
		return "", "", err
	}
	return capText(text), "", nil
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
		return capBytes(s, fetchMaxBytes) + "\n[truncated at 50KB]"
	}
	return s
}
