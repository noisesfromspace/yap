package lsp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"os"
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/document"
)

func TestApplyChange(t *testing.T) {
	// A transcript with an astral-plane rune (surrogate pair in UTF-16).
	text := "# @user\nhello 🚀 world\n"
	// Insert "X" after the emoji: emoji is 2 UTF-16 units, so column 6 + 2 = 8.
	ch := changeEvent{
		Range: rng{Start: position{Line: 1, Character: 8}, End: position{Line: 1, Character: 8}},
		Text:  "X",
	}
	got := applyChange(text, ch)
	want := "# @user\nhello 🚀X world\n"
	if got != want {
		t.Fatalf("applyChange = %q, want %q", got, want)
	}

	// Range delete across lines.
	text2 := "ab\ncd\n"
	ch2 := changeEvent{
		Range: rng{Start: position{Line: 0, Character: 1}, End: position{Line: 1, Character: 1}},
		Text:  "",
	}
	if got, want := applyChange(text2, ch2), "ad\n"; got != want {
		t.Fatalf("applyChange = %q, want %q", got, want)
	}
}

func TestSymbols(t *testing.T) {
	text := "---\ntitle: x\n---\n# @user\nInvestigate the parser\n# @assistant\n<!-- yap:tool {\"id\":\"t1\",\"name\":\"read\",\"arguments\":{}} -->\nresult\n<!-- /yap:tool -->\n"
	syms := Symbols(text)
	if len(syms) != 3 { // frontmatter + user + assistant
		t.Fatalf("got %d top-level symbols, want 3: %+v", len(syms), syms)
	}
	if syms[0].Name != "frontmatter" {
		t.Fatalf("symbol 0 = %q, want frontmatter", syms[0].Name)
	}
	if syms[1].Name != "user: Investigate the parser" {
		t.Fatalf("symbol 1 = %q", syms[1].Name)
	}
	asst := syms[2]
	if !strings.HasPrefix(asst.Name, "assistant:") {
		t.Fatalf("symbol 2 = %q, want assistant preview", asst.Name)
	}
	if len(asst.Children) != 1 || asst.Children[0].Name != "tool: read" {
		t.Fatalf("assistant children = %+v, want one tool: read", asst.Children)
	}
}

func TestCompletionFrontmatter(t *testing.T) {
	text := "---\nprov\n---\n# @user\nhi\n"
	items := Completion(text, 1, 4, CompletionCtx{})
	if len(items) == 0 {
		t.Fatal("no frontmatter key completions for 'prov'")
	}
	for _, it := range items {
		if it.Label == "provider" {
			return
		}
	}
	t.Fatalf("provider not offered for 'prov': %+v", items)
}

func TestCompletionRole(t *testing.T) {
	text := "# @u\n"
	items := Completion(text, 0, 4, CompletionCtx{})
	if len(items) == 0 || items[0].Label != "user" {
		t.Fatalf("role completion = %+v, want user", items)
	}
}

func TestCompletionFileRefAtLineStart(t *testing.T) {
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "readme.txt"), []byte("x"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A bare `@` at the start of a message body line: the word begins at
	// column 0, which isFileRef must accept as a reference position.
	items := Completion("# @user\n@\n", 1, 1, CompletionCtx{Cwd: dir})
	if len(items) == 0 {
		t.Fatal("no file completions for bare @ at line start")
	}
	found := false
	for _, it := range items {
		if it.Label == "readme.txt" {
			found = true
		}
	}
	if !found {
		t.Fatalf("readme.txt not offered for bare @: %+v", items)
	}
}

func TestCompletionNoMatchesEncodesAsArray(t *testing.T) {
	// A completion request with no matches must still return items: [], never
	// null: Neovim rejects null for a CompletionList.items field.
	var in bytes.Buffer
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize",
		"params": map[string]any{"initializationOptions": map[string]any{"sessions_dir": "/tmp/sessions"}},
	}))
	uri := "file:///tmp/sessions/a/session.md"
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "method": "textDocument/didOpen",
		"params": map[string]any{"textDocument": map[string]any{
			"uri": uri, "version": 1, "text": "# @user\njust some prose\n",
		}},
	}))
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "textDocument/completion",
		"params": map[string]any{
			"textDocument": map[string]any{"uri": uri},
			"position":     map[string]any{"line": 1, "character": 5},
		},
	}))
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "id": 3, "method": "shutdown"}))
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "method": "exit"}))

	var out bytes.Buffer
	if err := Serve(&in, &out); err != nil {
		t.Fatalf("Serve: %v", err)
	}
	for _, m := range splitFrames(out.Bytes()) {
		var resp struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(m, &resp) != nil || resp.ID != 2 {
			continue
		}
		var res struct {
			Items json.RawMessage `json:"items"`
		}
		if err := json.Unmarshal(resp.Result, &res); err != nil {
			t.Fatalf("unmarshal completion result: %v", err)
		}
		if string(res.Items) != "[]" {
			t.Fatalf("completion items = %s, want []", res.Items)
		}
		return
	}
	t.Fatal("no completion response with id 2")
}

func TestModelCompletionFromCache(t *testing.T) {
	cache := filepath.Join(t.TempDir(), "models")
	if err := os.WriteFile(cache, []byte("openai/gpt-6.1-sol\ndeepseek/deepseek-flash\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// `model:` completion strips the provider prefix from cached combos.
	text := "---\nprovider: openai\nmodel:\n---\n# @user\nhi\n"
	items := Completion(text, 2, 6, CompletionCtx{ModelsCache: cache})
	if len(items) != 1 || items[0].Label != "gpt-6.1-sol" {
		t.Fatalf("model completion = %+v, want [gpt-6.1-sol]", items)
	}
}

func TestDiagnostics(t *testing.T) {
	// Unterminated frontmatter.
	text := "---\ntitle: x\n# @user\nhi\n"
	diags := Diagnostics(text, false)
	if len(diags) == 0 || !strings.Contains(diags[0].Message, "unterminated") {
		t.Fatalf("expected unterminated frontmatter diagnostic, got %+v", diags)
	}

	// Unknown role.
	text2 := "# @badrole\nhi\n"
	diags2 := Diagnostics(text2, false)
	found := false
	for _, d := range diags2 {
		if strings.Contains(d.Message, "unknown message role") {
			found = true
		}
	}
	if !found {
		t.Fatalf("expected unknown role diagnostic, got %+v", diags2)
	}

	// Unclosed region suppressed while streaming, present when idle.
	text3 := "# @assistant\n<!-- yap:tool {\"id\":\"t\",\"name\":\"read\",\"arguments\":{}} -->\npartial\n"
	if got := Diagnostics(text3, true); len(got) != 0 {
		t.Fatalf("streaming should suppress unclosed-region diagnostics, got %+v", got)
	}
	if got := Diagnostics(text3, false); len(got) == 0 {
		t.Fatal("idle should report unclosed region")
	}
}

func TestDiagnosticsEmptyEncodesAsArray(t *testing.T) {
	// A clean document must still publish `diagnostics: []`, never `null`:
	// Neovim decodes `null` as vim.NIL (userdata) and its publishDiagnostics
	// handler then fails on `#diagnostics`.
	got := Diagnostics("# @user\nhi\n", false)
	if got == nil {
		t.Fatal("Diagnostics returned nil for a clean document")
	}
	b, err := json.Marshal(got)
	if err != nil {
		t.Fatal(err)
	}
	if string(b) != "[]" {
		t.Fatalf("empty diagnostics marshaled to %s, want []", b)
	}
}

func TestParseParity(t *testing.T) {
	// Spot-check the document parser the LSP builds on, for the recovery that
	// most affects symbols: a closed tool region keeps a quoted heading as
	// content, an unclosed one promotes it.
	closed := document.Parse("# @assistant\n<!-- yap:tool {\"id\":\"t\",\"name\":\"read\",\"arguments\":{}} -->\n# @user\n<!-- /yap:tool -->\n")
	if len(closed.Headings) != 1 || closed.Headings[0].Role != "assistant" {
		t.Fatalf("closed tool headings = %+v, want only assistant", closed.Headings)
	}
	open := document.Parse("# @assistant\n<!-- yap:tool {\"id\":\"t\",\"name\":\"read\",\"arguments\":{}} -->\n# @user\n")
	if len(open.Headings) != 2 || open.Headings[1].Role != "user" {
		t.Fatalf("open tool headings = %+v, want assistant+user", open.Headings)
	}
	if !open.Regions[0].Unclosed {
		t.Fatal("open tool region should be marked unclosed")
	}
}

// frame builds a single Content-Length framed LSP message.
func frame(v any) []byte {
	b, _ := json.Marshal(v)
	return []byte(fmt.Sprintf("Content-Length: %d\r\n\r\n", len(b)) + string(b))
}

// TestServeEndToEnd drives the server through framing, sync and one request.
func TestServeEndToEnd(t *testing.T) {
	var in bytes.Buffer
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize",
		"params": map[string]any{
			"initializationOptions": map[string]any{"sessions_dir": "/tmp/sessions"},
		},
	}))
	uri := "file:///tmp/sessions/a/session.md"
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "method": "textDocument/didOpen",
		"params": map[string]any{
			"textDocument": map[string]any{
				"uri": uri, "version": 1,
				"text": "# @user\nhi\n",
			},
		},
	}))
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "id": 2, "method": "textDocument/documentSymbol",
		"params": map[string]any{"textDocument": map[string]any{"uri": uri}},
	}))
	in.Write(frame(map[string]any{
		"jsonrpc": "2.0", "id": 3, "method": "textDocument/completion",
		"params": map[string]any{
			"textDocument": map[string]any{"uri": uri},
			"position":     map[string]any{"line": 0, "character": 5},
		},
	}))
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "id": 4, "method": "shutdown"}))
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "method": "exit"}))

	var out bytes.Buffer
	if err := Serve(&in, &out); err != nil {
		t.Fatalf("Serve: %v", err)
	}

	msgs := splitFrames(out.Bytes())
	if len(msgs) == 0 {
		t.Fatal("no responses written")
	}
	// First response is initialize; find the documentSymbol response by id.
	var foundSymbols bool
	for _, m := range msgs {
		var resp struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(m, &resp) != nil {
			continue
		}
		if resp.ID == 2 {
			var syms []map[string]any
			if err := json.Unmarshal(resp.Result, &syms); err != nil {
				t.Fatalf("documentSymbol result not a list: %s", resp.Result)
			}
			if len(syms) != 1 {
				t.Fatalf("got %d symbols, want 1", len(syms))
			}
			foundSymbols = true
		}
	}
	if !foundSymbols {
		t.Fatal("no documentSymbol response with id 2")
	}
}

func splitFrames(b []byte) [][]byte {
	var out [][]byte
	for {
		i := bytes.Index(b, []byte("\r\n\r\n"))
		if i < 0 {
			return out
		}
		header := string(b[:i])
		var n int
		_, _ = fmt.Sscanf(header, "Content-Length: %d", &n)
		start := i + 4
		if start+n > len(b) {
			return out
		}
		out = append(out, b[start:start+n])
		b = b[start+n:]
	}
}

// BenchmarkApplyChangeTail measures the per-change sync cost: Neovim sends an
// incremental didChange per edit, and applyChange re-splices the whole
// document. A tail append is the streaming hot path, so positionToByte walks
// from the top and the splice copies the full text.
func BenchmarkApplyChangeTail(b *testing.B) {
	for _, lines := range []int{12000, 60000, 120000} {
		text := strings.Repeat("some transcript prose with a reasonable line length\n", lines)
		b.Run(fmt.Sprintf("lines=%d", lines), func(b *testing.B) {
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				ch := changeEvent{
					Range: rng{Start: position{Line: lines - 1, Character: 0}, End: position{Line: lines - 1, Character: 0}},
					Text:  "appended\n",
				}
				_ = applyChange(text, ch)
			}
		})
	}
}
