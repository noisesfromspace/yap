package tools

import (
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// fetchMaxBytes caps the body sent to the model.
const fetchMaxBytes = 50 * 1024

type fetchArgs struct {
	URL string `json:"url" jsonschema:"description=http(s) URL to fetch"`
}

func init() {
	Register("fetch",
		"Fetch a URL over HTTP(S) and return the response body as text (truncated to 50KB).",
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
			body, err := io.ReadAll(io.LimitReader(resp.Body, fetchMaxBytes+1))
			if err != nil {
				return "", "", err
			}
			text := string(body)
			if len(body) > fetchMaxBytes {
				text = string(body[:fetchMaxBytes]) + "\n[truncated at 50KB]"
			}
			return text, "", nil
		})
}
