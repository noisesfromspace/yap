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
	URL    string `json:"url" jsonschema:"description=http(s) URL to fetch"`
	Safety bool   `json:"safety,omitempty" jsonschema:"description=when true, run a jev prompt-injection check on the result before returning it; flagged content is annotated with a warning (costs one extra decision-model call, so use only for untrusted content)"`
}

func init() {
	Register("fetch",
		"Fetch a URL over HTTP(S) and return the main content as Markdown. "+
			"HTML pages are run through readability extraction (strips nav, sidebars, ads, scripts) and converted to Markdown; "+
			"non-HTML bodies (JSON, plain text, …) are returned as-is. Truncated to 50KB. "+
			"Use curl for raw HTML inspection.",
		func(a *fetchArgs) (string, string, error) {
			if !strings.HasPrefix(a.URL, "http://") && !strings.HasPrefix(a.URL, "https://") {
				return "", "", fmt.Errorf("only http(s) URLs supported")
			}

			client := &http.Client{Timeout: 30 * time.Second}
			resp, err := client.Get(a.URL)
			if err != nil {
				return "", "", err
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				return fmt.Sprintf("error: %s", resp.Status), "", nil
			}

			isHTML := isHTMLContentType(resp.Header.Get("Content-Type"))
			limit := fetchMaxBytes
			if isHTML {
				limit = fetchMaxHTMLBytes
			}
			body, err := io.ReadAll(io.LimitReader(resp.Body, int64(limit)+1))
			if err != nil {
				return "", "", err
			}

			if !isHTML {
				return safetyGuarded(a.Safety, capText(string(body))), "", nil
			}

			text, err := extractMarkdown(body, pageURL(resp.Request, a.URL))
			if err != nil {
				// Extraction failed (e.g. the page is not an article): fall
				// back to converting the whole page, mirroring the old
				// raw-HTML path but still returning Markdown, not tags.
				if md, mdErr := htmltomarkdown.ConvertString(string(body)); mdErr == nil {
					return safetyGuarded(a.Safety, capText(md)), "", nil
				}
				return "", "", err
			}
			return safetyGuarded(a.Safety, capText(text)), "", nil
		})
}

func isHTMLContentType(contentType string) bool {
	mt, _, err := mime.ParseMediaType(contentType)
	if err != nil {
		return false
	}
	return mt == "text/html" || mt == "application/xhtml+xml"
}

// pageURL returns the final URL after redirects, so readability can turn
// relative links/images into absolute ones. The request URL is always set
// on a successful response; the fallback keeps the tool honest if it isn't.
func pageURL(req *http.Request, raw string) *url.URL {
	if req != nil && req.URL != nil {
		return req.URL
	}
	u, _ := url.Parse(raw)
	return u
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
