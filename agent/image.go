package main

import (
	"encoding/base64"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"regexp"

	"boers.email/yap/agent/llm"
)

const maxImageBytes = 10 << 20

// Only explicit FILE image references are attachments; ordinary Markdown and
// pasted paths remain text. The saved transcript contains no encoded bytes.
var imageReference = regexp.MustCompile(`!\[FILE: ([^\]\n]+)\]\((file:///[^\s)]+)\)`)

func userParts(text string) ([]llm.Part, error) {
	var parts []llm.Part
	start := 0
	for _, match := range imageReference.FindAllStringSubmatchIndex(text, -1) {
		if match[0] > start {
			parts = append(parts, llm.Part{Type: llm.PartText, Text: text[start:match[0]]})
		}
		uri := text[match[4]:match[5]]
		u, err := url.Parse(uri)
		if err != nil || u.Scheme != "file" || u.Host != "" || u.Path == "" {
			return nil, fmt.Errorf("invalid image reference %q", uri)
		}
		f, err := os.Open(u.Path)
		if err != nil {
			return nil, fmt.Errorf("open image %q: %w", u.Path, err)
		}
		data, readErr := io.ReadAll(io.LimitReader(f, maxImageBytes+1))
		closeErr := f.Close()
		if readErr != nil {
			return nil, fmt.Errorf("read image %q: %w", u.Path, readErr)
		}
		if closeErr != nil {
			return nil, fmt.Errorf("close image %q: %w", u.Path, closeErr)
		}
		if len(data) > maxImageBytes {
			return nil, fmt.Errorf("image %q exceeds 10 MiB", u.Path)
		}
		mediaType := http.DetectContentType(data)
		if mediaType != "image/png" && mediaType != "image/jpeg" {
			return nil, fmt.Errorf("image %q is not PNG or JPEG (%s)", u.Path, mediaType)
		}
		parts = append(parts, llm.Part{Type: llm.PartImage, URL: "data:" + mediaType + ";base64," + base64.StdEncoding.EncodeToString(data)})
		start = match[1]
	}
	if start < len(text) {
		parts = append(parts, llm.Part{Type: llm.PartText, Text: text[start:]})
	}
	return parts, nil
}
