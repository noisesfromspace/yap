package tools

import (
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// fetchMaxBytes caps the body sent to the model.
const fetchMaxBytes = 50 * 1024

func init() {
	Register(&Tool{
		Name:        "fetch",
		Description: "Fetch a URL over HTTP(S) and return the response body as text (truncated to 50KB).",
		Schema: `{"type":"object","properties":{
			"url":{"type":"string","description":"http(s) URL to fetch"}},
			"required":["url"]}`,
		Run: func(args json.RawMessage) (string, string, error) {
			var a struct {
				URL string `json:"url"`
			}
			if err := json.Unmarshal(args, &a); err != nil {
				return "", "", err
			}
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
		},
	})
}
