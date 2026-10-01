package utils

import (
	"encoding/json"
	"path/filepath"
	"strings"
)

// resultFence returns the fenced-code info string for a tool whose
// result is raw content (read/bash/fetch), or ok=false for tools whose
// result is a short confirmation (write/edit) or an error message —
// those stay bare. Content-bearing results live in the chat buffer,
// which is markdown: raw file content or command output gets parsed by
// markdown_inline (links, emphasis, headings, <hr>) and picks up stray
// styling. Wrapping it in a fence renders it as code instead.
func ResultFence(name, argsJSON string) (lang string, ok bool) {
	switch name {
	case "read":
		var a struct {
			Path string `json:"path"`
		}
		json.Unmarshal([]byte(argsJSON), &a)
		return langForPath(a.Path), true
	case "fetch":
		return "html", true
	case "bash", "curl":
		return "", true // plain fence: command output is arbitrary text
	case "ls", "search", "glob":
		return "", true // plain fence: directory/listing output is arbitrary text
	default:
		return "", false
	}
}

func langForPath(p string) string {
	switch strings.TrimPrefix(strings.ToLower(filepath.Ext(p)), ".") {
	case "py":
		return "python"
	case "go":
		return "go"
	case "lua":
		return "lua"
	case "md", "markdown":
		return "markdown"
	case "yaml", "yml":
		return "yaml"
	case "json":
		return "json"
	case "nix":
		return "nix"
	case "sh", "bash":
		return "bash"
	case "js":
		return "javascript"
	case "ts":
		return "typescript"
	case "html", "htm":
		return "html"
	case "css":
		return "css"
	case "rs":
		return "rust"
	case "toml":
		return "toml"
	case "xml":
		return "xml"
	case "sql":
		return "sql"
	case "c":
		return "c"
	case "cpp", "cc", "cxx", "h", "hpp":
		return "cpp"
	default:
		return "" // plain fence when the extension is unrecognized
	}
}
