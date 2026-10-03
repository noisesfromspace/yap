package render

import (
	"encoding/json"
	"path/filepath"
	"strings"
)

// resultFence returns the fenced-code info string for a tool whose
// result is raw content (read/bash) or extracted content (fetch), or
// ok=false for tools whose result is a short confirmation (write/edit)
// or an error message — those stay bare. Content-bearing results live in
// the chat buffer, which is markdown: raw file content or command output
// gets parsed by markdown_inline (links, emphasis, headings, <hr>) and
// picks up stray styling. Wrapping it in a fence renders it as code
// instead.
func resultFence(name, argsJSON string) (lang string, ok bool) {
	switch name {
	case "read":
		var a struct {
			Path string `json:"path"`
		}
		json.Unmarshal([]byte(argsJSON), &a)
		return langForPath(a.Path), true
	case "fetch":
		return "markdown", true
	case "bash", "curl", "git", "ssh", "python":
		return "", true // plain fence: command output is arbitrary text
	case "ls", "search", "glob":
		return "", true // plain fence: directory/listing output is arbitrary text
	default:
		return "", false
	}
}

// langByExt maps a file extension (lowercase, no dot) to the Neovim
// treesitter language name used as the fence info string. These must be
// treesitter parser names, not file extensions — a wrong name means the
// fence gets no injected highlighting (silently), so only well-established
// nvim-treesitter parser names belong here.
var langByExt = map[string]string{
	"py":  "python",
	"go":  "go",
	"lua": "lua",
	"md":  "markdown", "markdown": "markdown", "mdx": "markdown",
	"yaml": "yaml", "yml": "yaml",
	"json": "json", "jsonc": "jsonc", "json5": "json5",
	"nix": "nix",
	"sh":  "bash", "bash": "bash", "zsh": "bash",
	"js": "javascript", "jsx": "javascript", "mjs": "javascript", "cjs": "javascript",
	"ts": "typescript", "tsx": "tsx", "mts": "typescript", "cts": "typescript",
	"html": "html", "htm": "html",
	"css": "css", "scss": "scss",
	"rs":   "rust",
	"toml": "toml",
	"xml":  "xml",
	"sql":  "sql",
	"c":    "c",
	"cpp":  "cpp", "cc": "cpp", "cxx": "cpp", "h": "cpp", "hpp": "cpp", "hh": "cpp", "hxx": "cpp",
	"cs":   "c_sharp",
	"java": "java",
	"kt":   "kotlin", "kts": "kotlin",
	"scala": "scala", "sc": "scala",
	"rb":    "ruby",
	"php":   "php",
	"swift": "swift",
	"zig":   "zig",
	"dart":  "dart",
	"hs":    "haskell",
	"ex":    "elixir", "exs": "elixir",
	"erl": "erlang", "hrl": "erlang",
	"clj": "clojure", "cljs": "clojure", "cljc": "clojure", "edn": "clojure",
	"scm": "scheme", "ss": "scheme",
	"lisp": "commonlisp", "lsp": "commonlisp", "cl": "commonlisp",
	"r":  "r",
	"jl": "julia",
	"fs": "fsharp", "fsx": "fsharp", "fsi": "fsharp",
	"ml": "ocaml", "mli": "ocaml",
	"fish": "fish",
	"pl":   "perl", "pm": "perl",
	"ps1": "powershell", "psm1": "powershell", "psd1": "powershell",
	"cmake":   "cmake",
	"graphql": "graphql", "gql": "graphql",
	"proto": "proto",
	"tf":    "hcl", "hcl": "hcl", "tfvars": "hcl",
	"vue":    "vue",
	"svelte": "svelte",
	"astro":  "astro",
	"sol":    "solidity",
	"vim":    "vim",
	"diff":   "diff", "patch": "diff",
	"csv": "csv",
}

// langForPath returns the fence info string (treesitter language name)
// for a file path, or "" when the path has no recognized extension. A
// special-case handles extension-less names (Dockerfile, Makefile).
func langForPath(p string) string {
	base := strings.ToLower(filepath.Base(p))
	if base == "dockerfile" {
		return "dockerfile"
	}
	if base == "makefile" {
		return "make"
	}
	return langByExt[strings.TrimPrefix(strings.ToLower(filepath.Ext(p)), ".")]
}

// fenceRun reports the leading fence run of a line already trimmed of
// indent: (char, run-length, remainder-after-the-run). char is 0 when the
// line does not open a fence.
func fenceRun(s string) (byte, int, string) {
	if s == "" || (s[0] != '`' && s[0] != '~') {
		return 0, 0, ""
	}
	i := 0
	for i < len(s) && s[i] == s[0] {
		i++
	}
	return s[0], i, s[i:]
}

// fenceLine classifies a RAW line as a fence opener: up to 3 leading
// spaces, then a run of >=3 backticks or tildes. Returns (char, run,
// tail, ok). This is the CommonMark "is this line a fence" primitive;
// Lua's fold.fence_run must agree with it — they are locked together by
// the shared table in tests/fence_cases.json (see fence_conformance_test.go
// and yap_fence_conformance_test.lua).
func fenceLine(line string) (byte, int, string, bool) {
	t := strings.TrimLeft(line, " ")
	if len(line)-len(t) > 3 {
		return 0, 0, "", false
	}
	c, k, tail := fenceRun(t)
	if k < 3 {
		return 0, 0, "", false
	}
	return c, k, tail, true
}

// unclosedFence returns the fence run left open at the end of lines
// (e.g. "```"), or "" when all fences balance. Follows CommonMark: an
// opener is up to 3 spaces + a run of >=3 backticks or tildes; a closer
// is a run of the same char at least as long, followed only by
// whitespace (an info string after a closer keeps the fence open).
func unclosedFence(lines []string) string {
	var char byte
	var n int
	for _, l := range lines {
		c, k, tail, ok := fenceLine(l)
		if !ok {
			continue
		}
		if n == 0 {
			char, n = c, k
		} else if c == char && k >= n && strings.TrimSpace(tail) == "" {
			char, n = 0, 0
		}
	}
	if n == 0 {
		return ""
	}
	return strings.Repeat(string(char), n)
}

// backtickFence returns a run of backticks one longer than any run in s
// (min 3), so s can be embedded in a fenced block it cannot close early.
func backtickFence(s string) string {
	max := 0
	for _, l := range strings.Split(s, "\n") {
		if c, k, _, ok := fenceLine(l); ok && c == '`' && k > max {
			max = k
		}
	}
	n := max + 1
	if n < 3 {
		n = 3
	}
	return strings.Repeat("`", n)
}

// FenceResult wraps a content-bearing tool result in a fenced code
// block (with a language info string when detectable) so the chat
// buffer's markdown parser renders it as code, not prose — raw file
// content and command output otherwise get markdown_inline styling
// (links, emphasis, headings, <hr>). The fence is one backtick longer
// than any run inside, so content fences can't close it early. Applied
// to the SAME string that goes to the model, so the buffer and the
// replayed history stay identical across turns.
func FenceResult(name, argsJSON, result string) string {
	lang, ok := resultFence(name, argsJSON)
	if !ok {
		return result
	}
	if name == "python" && isJSON(result) {
		lang = "json" // printed JSON (json.dumps, ...) gets real highlighting
	}
	fence := backtickFence(result)
	return fence + lang + "\n" + strings.TrimRight(result, "\n") + "\n" + fence
}

// isJSON reports whether s is a complete JSON object or array — the
// common python-tool case of printing a serialized payload, where a
// ```json fence gives syntax highlighting instead of a plain code block.
func isJSON(s string) bool {
	t := strings.TrimSpace(s)
	if t == "" || (t[0] != '{' && t[0] != '[') {
		return false
	}
	return json.Valid([]byte(t))
}
