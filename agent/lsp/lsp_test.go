package lsp

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"

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
	text := "---\ntitle: x\n---\n# @user\nInvestigate the parser\n# @assistant\n<!-- yap:thinking\nsecret reasoning\n-->\n<!-- yap:tool {\"id\":\"t1\",\"name\":\"read\",\"arguments\":{}} -->\nresult\n<!-- /yap:tool -->\nvisible answer\n"
	syms := Symbols(text)
	if len(syms) != 3 { // frontmatter + user + assistant
		t.Fatalf("got %d top-level symbols, want 3: %+v", len(syms), syms)
	}
	// Newest first, frontmatter last.
	asst := syms[0]
	if asst.Name != "assistant: visible answer" {
		t.Fatalf("symbol 0 = %q, want the first visible prose, skipping thinking and tool bodies", asst.Name)
	}
	if len(asst.Children) != 0 {
		t.Fatalf("assistant children = %+v, want none (tool calls are not symbols)", asst.Children)
	}
	if syms[1].Name != "user: Investigate the parser" {
		t.Fatalf("symbol 1 = %q", syms[1].Name)
	}
	if syms[2].Name != "frontmatter" {
		t.Fatalf("symbol 2 = %q, want frontmatter", syms[2].Name)
	}
}

func TestSymbolsEmptyAndError(t *testing.T) {
	text := "# @user\nask\n# @assistant\n<!-- yap:thinking\nsecret\n-->\n<!-- yap:error\nfailed on purpose\n-->\n# @user\n"
	syms := Symbols(text)
	if len(syms) != 2 { // errored assistant + user; empty trailing user dropped
		t.Fatalf("got %d symbols, want 2: %+v", len(syms), syms)
	}
	// Newest first: the errored assistant, then the user that preceded it.
	if syms[0].Name != "assistant: failed on purpose" {
		t.Fatalf("symbol 0 = %q, want the error naming a no-visible-prose turn", syms[0].Name)
	}
	if syms[1].Name != "user: ask" {
		t.Fatalf("symbol 1 = %q", syms[1].Name)
	}
}

func TestSymbolsSubagents(t *testing.T) {
	text := "---\ntitle: x\n---\n# @user\nlook into it\n# @assistant\n<!-- yap:tool {\"id\":\"s1\",\"name\":\"subagent\",\"arguments\":{\"agent\":\"scout\",\"task\":\"survey the code\",\"tools\":[\"read\"]}} -->\nchild answer\n<!-- /yap:tool -->\nsummary\n"
	syms := Symbols(text)
	if len(syms) != 3 { // frontmatter + user + assistant
		t.Fatalf("got %d top-level symbols, want 3: %+v", len(syms), syms)
	}
	asst := syms[0]
	if asst.Name != "assistant: summary" {
		t.Fatalf("assistant = %q, want its first visible prose, skipping the subagent body", asst.Name)
	}
	if len(asst.Children) != 1 {
		t.Fatalf("assistant children = %+v, want one subagent", asst.Children)
	}
	sub := asst.Children[0]
	if sub.Name != "scout · survey the code" {
		t.Fatalf("subagent name = %q", sub.Name)
	}
	// The subagent header sits on 0-based line 6 (1-based line 7).
	if sub.Range.Start.Line != 6 || sub.SelectionRange.Start.Line != 6 {
		t.Fatalf("subagent range = %+v", sub)
	}
	if sub.Range.End.Line != 9 { // exclusive end: the closer is 0-based line 8
		t.Fatalf("subagent end = %d, want 9", sub.Range.End.Line)
	}
	if syms[1].Name != "user: look into it" {
		t.Fatalf("user = %q", syms[1].Name)
	}
}

func TestSymbolsSubagentOnlyMessage(t *testing.T) {
	// A turn that only invokes a subagent has no visible prose, so it would
	// otherwise drop; its subagent child keeps it reachable.
	text := "# @assistant\n<!-- yap:tool {\"id\":\"s1\",\"name\":\"subagent\",\"arguments\":{\"agent\":\"audit\"}} -->\npartial\n"
	syms := Symbols(text)
	if len(syms) != 1 {
		t.Fatalf("got %d symbols, want 1: %+v", len(syms), syms)
	}
	asst := syms[0]
	if asst.Name != "assistant: subagent" {
		t.Fatalf("assistant = %q, want a subagent fallback name", asst.Name)
	}
	if len(asst.Children) != 1 || asst.Children[0].Name != "audit" {
		t.Fatalf("assistant children = %+v, want the audit subagent", asst.Children)
	}
}

func TestSymbolsSubagentMultipleAndRead(t *testing.T) {
	text := "# @assistant\n<!-- yap:tool {\"id\":\"r1\",\"name\":\"read\",\"arguments\":{}} -->\nfile\n<!-- /yap:tool -->\n<!-- yap:tool {\"id\":\"s1\",\"name\":\"subagent\",\"arguments\":{\"agent\":\"scout\",\"task\":\"a\"}} -->\n\n<!-- /yap:tool -->\n<!-- yap:tool {\"id\":\"s2\",\"name\":\"subagent\",\"arguments\":{\"agent\":\"audit\",\"task\":\"b\"}} -->\n\n<!-- /yap:tool -->\ndone\n"
	syms := Symbols(text)
	if len(syms) != 1 {
		t.Fatalf("got %d top-level symbols, want 1: %+v", len(syms), syms)
	}
	children := syms[0].Children
	if len(children) != 2 {
		t.Fatalf("children = %+v, want only the two subagents (read is not a symbol)", children)
	}
	if children[0].Name != "scout · a" || children[1].Name != "audit · b" {
		t.Fatalf("subagent names = %q, %q", children[0].Name, children[1].Name)
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

func TestPreviousMapCompletion(t *testing.T) {
	cache := filepath.Join(t.TempDir(), "models")
	if err := os.WriteFile(cache, []byte("openai/gpt-6.1-sol\ndeepseek/deepseek-flash\n"), 0o600); err != nil {
		t.Fatal(err)
	}
	// A `previous:` entry completes the combo key from the cached list.
	text := "---\nprevious:\n  openai/g\n---\n# @user\nhi\n"
	items := Completion(text, 2, 10, CompletionCtx{ModelsCache: cache})
	if len(items) != 2 || items[0].Label != "openai/gpt-6.1-sol" || items[1].Label != "deepseek/deepseek-flash" {
		t.Fatalf("previous completion = %+v, want both cached combos", items)
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

func TestCodeActions(t *testing.T) {
	uri := "file:///tmp/sessions/a/session.md"
	var in bytes.Buffer
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": map[string]any{
		"initializationOptions": map[string]any{"sessions_dir": "/tmp/sessions"},
	}}))
	text := "---\ntitle: x\n# @assistant\n<!-- yap:tool {\"id\":\"t\",\"name\":\"read\"} -->\nresult\n# @user\nhello\n"
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "method": "textDocument/didOpen", "params": map[string]any{
		"textDocument": map[string]any{"uri": uri, "text": text, "version": 1},
	}}))
	for id, line := range []int{0, 3, 6} {
		in.Write(frame(map[string]any{"jsonrpc": "2.0", "id": id + 2, "method": "textDocument/codeAction", "params": map[string]any{
			"textDocument": map[string]any{"uri": uri},
			"range":        rng{Start: position{Line: line}, End: position{Line: line}},
		}}))
	}
	in.Write(frame(map[string]any{"jsonrpc": "2.0", "method": "exit"}))
	var out bytes.Buffer
	if err := Serve(&in, &out); err != nil {
		t.Fatal(err)
	}
	want := map[int]string{2: "---\n", 3: "<!-- /yap:tool -->\n"}
	for _, raw := range splitFrames(out.Bytes()) {
		var resp struct {
			ID     int             `json:"id"`
			Result json.RawMessage `json:"result"`
		}
		if json.Unmarshal(raw, &resp) != nil || resp.ID < 2 || resp.ID > 4 {
			continue
		}
		var actions []struct {
			Edit struct {
				Changes map[string][]textEdit `json:"changes"`
			} `json:"edit"`
		}
		if err := json.Unmarshal(resp.Result, &actions); err != nil {
			t.Fatal(err)
		}
		if resp.ID == 4 {
			if len(actions) != 0 {
				t.Fatalf("unrelated range: %+v", actions)
			}
			continue
		}
		if len(actions) != 1 || len(actions[0].Edit.Changes[uri]) != 1 || actions[0].Edit.Changes[uri][0].NewText != want[resp.ID] {
			t.Fatalf("action %d: %+v", resp.ID, actions)
		}
		edit := actions[0].Edit.Changes[uri][0]
		fixed := applyChange(text, changeEvent{Range: edit.Range, Text: edit.NewText})
		if resp.ID == 2 && !strings.Contains(fixed, "---\n# @assistant") || resp.ID == 3 && !strings.Contains(fixed, "<!-- /yap:tool -->\n# @user") {
			t.Fatalf("action %d did not close boundary: %q", resp.ID, fixed)
		}
	}
}

func TestCodeActionsGuarded(t *testing.T) {
	uri := "file:///tmp/sessions/a/session.md"
	s := New(&bytes.Buffer{}, InitOptions{SessionsDir: "/tmp/sessions"})
	p := codeActionParams{Range: rng{Start: position{Line: 1}, End: position{Line: 1}}}
	p.TextDocument.URI = uri
	for _, tc := range []struct {
		name, text string
		streaming  bool
	}{
		{"clean", "# @user\nhello\n", false},
		{"unfinished header", "# @assistant\n<!-- yap:tool\npartial\n", false},
		{"streaming", "# @assistant\n<!-- yap:tool {\"id\":\"t\",\"name\":\"read\"} -->\npartial\n", true},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s.docs[uri] = &docState{text: tc.text, streaming: tc.streaming}
			if actions := s.codeActionsFor(p).([]any); len(actions) != 0 {
				t.Fatalf("unsafe actions: %+v", actions)
			}
		})
	}
	p.TextDocument.URI = "file:///tmp/ordinary.md"
	if actions := s.codeActionsFor(p).([]any); len(actions) != 0 {
		t.Fatalf("non-session actions: %+v", actions)
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

// BenchmarkSymbols isolates the documentSymbol request cost: structural
// parse, symbol-tree build and JSON encoding, at transcript sizes where the
// picker is asked for thousands of symbols.
func BenchmarkSymbols(b *testing.B) {
	for _, turns := range []int{2000, 5000} {
		text := benchmarkTranscript(turns)
		b.Run(fmt.Sprintf("turns=%d", turns), func(b *testing.B) {
			for i := 0; i < b.N; i++ {
				syms := Symbols(text)
				if _, err := json.Marshal(syms); err != nil {
					b.Fatal(err)
				}
			}
		})
	}
}

func benchmarkTranscript(turns int) string {
	var sb strings.Builder
	sb.WriteString("---\ntitle: bench\nprovider: openai\nmodel: m1\n---\n")
	for i := 0; i < turns; i++ {
		fmt.Fprintf(&sb, "# @user\nInvestigate the session parser and navigation for issue %d.\n\n", i)
		fmt.Fprintf(&sb, "# @assistant\n<!-- yap:tool {\"id\":\"t%d\",\"name\":\"read\",\"arguments\":{\"path\":\"/tmp/x\"}} -->\n", i)
		sb.WriteString("Here is a representative result line with some prose to parse.\n```\ndef f(x):\n    return x\n```\n<!-- /yap:tool -->\n\n")
	}
	return sb.String()
}

// TestDocParseCachesPerVersion: the cached parse is reused while the version
// is unchanged and invalidated as soon as an edit lands, so symbols and
// diagnostics never read a stale structure.
func TestDocParseCachesPerVersion(t *testing.T) {
	d := &docState{text: "# @user\nhi\n", version: 1}
	p1 := d.parse()
	if p1 != d.parse() {
		t.Fatal("parse() did not reuse the cached parse for the same version")
	}

	d.mu.Lock()
	d.text = "# @user\nhi\n# @assistant\nreply\n"
	d.version = 2
	d.mu.Unlock()

	p2 := d.parse()
	if p2 == p1 {
		t.Fatal("parse() returned the cached parse after an edit")
	}
	if len(p2.Headings) != 2 {
		t.Fatalf("reparsed headings = %+v, want 2", p2.Headings)
	}
}

// TestDocWarmPopulatesCache: warm() parses off the read loop, so the first
// symbol request after a load finds the structure ready.
func TestDocWarmPopulatesCache(t *testing.T) {
	d := &docState{text: "# @user\nhi\n# @assistant\nreply\n", version: 1}
	d.warm()
	for i := 0; i < 500; i++ {
		d.mu.Lock()
		warm := d.parsed
		d.mu.Unlock()
		if warm != nil {
			if got := d.parse(); got != warm {
				t.Fatal("parse() did not reuse the warmed parse")
			}
			return
		}
		time.Sleep(2 * time.Millisecond)
	}
	t.Fatal("warm() never populated the cache")
}

// TestMessagesRequestServesGoConversion: the harness asks the server what a
// send would contain instead of deriving it in Lua (R-single-reader). This
// exercises the yap/messages request end to end, including an empty result
// encoding as [] rather than null.
func TestSessionTranscriptRecognition(t *testing.T) {
	s := New(io.Discard, InitOptions{SessionsDir: "/tmp/sessions"})
	if !s.isSession("file:///tmp/sessions/a/my-title.md") {
		t.Fatal("renamed transcript was not recognized")
	}
	if s.isSession("file:///tmp/sessions/a/notes.md") {
		t.Fatal("scratch notes were recognized as a session")
	}
	if s.isSession("file:///tmp/other/my-title.md") {
		t.Fatal("markdown outside the session root was recognized")
	}

	// A client-marked transcript outside sessions_dir is a session: the yap
	// client only attaches to session buffers, so the path cannot be the only
	// signal once transcripts can live anywhere.
	outside := "file:///tmp/other/portable-session.md"
	s.docs[outside] = &docState{session: true}
	if !s.isSession(outside) {
		t.Fatal("client-marked transcript outside the root was not recognized")
	}
}

func TestScratchCompletionOnlyFiles(t *testing.T) {
	cwd := t.TempDir()
	if err := os.WriteFile(filepath.Join(cwd, "flake.nix"), []byte(""), 0600); err != nil {
		t.Fatal(err)
	}
	s := New(io.Discard, InitOptions{SessionsDir: "/tmp/sessions"})
	uri := "file:///tmp/sessions/a/notes.md"
	s.docs[uri] = &docState{text: "# @steer\nsee @fla", cwd: cwd, scratch: true}
	request := func(line, col int) []completionItem {
		p := completionParams{Position: position{Line: line, Character: col}}
		p.TextDocument.URI = uri
		res := s.completionFor(p).(map[string]any)
		return res["items"].([]completionItem)
	}
	items := request(1, 8)
	if len(items) != 1 || items[0].Label != "flake.nix" {
		t.Fatalf("scratch @file completion = %+v", items)
	}
	if got := request(0, 5); len(got) != 1 || got[0].Label != "steer" {
		t.Fatalf("scratch heading completion = %+v", got)
	}
	if got := s.symbolsFor(uri).([]any); len(got) != 0 {
		t.Fatalf("scratch received transcript symbols: %+v", got)
	}
}

func TestFileCompletionMatchesAndSortsPaths(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{
		"a/sessions.go.bak", "agent/tools/sessions.go", "b/sessions.go", "z/release notes.md",
	} {
		p := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(p), 0o700); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(p, nil, 0o600); err != nil {
			t.Fatal(err)
		}
	}
	type match struct{ label, filter, insert string }
	for _, tc := range []struct {
		query string
		want  []match
	}{
		{"sess", []match{
			{"a/sessions.go.bak", "sessions.go.bak", "a/sessions.go.bak"},
			{"agent/tools/sessions.go", "sessions.go", "agent/tools/sessions.go"},
			{"b/sessions.go", "sessions.go", "b/sessions.go"},
		}},
		// Typing through an exact basename must not move it above an earlier path.
		{"sessions.go", []match{
			{"a/sessions.go.bak", "sessions.go.bak", "a/sessions.go.bak"},
			{"agent/tools/sessions.go", "sessions.go", "agent/tools/sessions.go"},
			{"b/sessions.go", "sessions.go", "b/sessions.go"},
		}},
		{"agent", []match{
			{"agent/", "agent", "agent/"},
			{"agent/tools/", "agent/tools/", "agent/tools/"},
			{"agent/tools/sessions.go", "agent/tools/sessions.go", "agent/tools/sessions.go"},
		}},
		{"agent/tools/sess", []match{
			{"agent/tools/sessions.go", "agent/tools/sessions.go", "agent/tools/sessions.go"},
		}},
		{"tools/sess", nil}, // A slash query cannot start inside a path.
		{"release", []match{
			{"z/release notes.md", "release notes.md", `"z/release notes.md"`},
		}},
	} {
		t.Run(tc.query, func(t *testing.T) {
			const prefix = "see @"
			line := prefix + tc.query
			items := Completion("# @user\n"+line, 1, len(line), CompletionCtx{Cwd: dir})
			if len(items) != len(tc.want) {
				t.Fatalf("items = %+v, want %+v", items, tc.want)
			}
			for i, it := range items {
				want := tc.want[i]
				if it.Label != want.label || it.FilterText != want.filter || it.InsertText != want.insert {
					t.Fatalf("item %d = %+v, want %+v", i, it, want)
				}
				r := rng{Start: position{Line: 1, Character: len(prefix)}, End: position{Line: 1, Character: len(line)}}
				if it.TextEdit == nil || it.TextEdit.Range != r || it.TextEdit.NewText != want.insert {
					t.Fatalf("edit = %+v, want %+v replacing only the query", it.TextEdit, textEdit{Range: r, NewText: want.insert})
				}
				if it.SortText != want.label {
					t.Fatalf("sortText = %q, want stable path %q", it.SortText, want.label)
				}
			}
		})
	}
}

func TestCompletionIncompleteForFileReferences(t *testing.T) {
	cwd := t.TempDir()
	if err := os.Mkdir(filepath.Join(cwd, "nested"), 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(cwd, "nested", "sessions.go"), nil, 0o600); err != nil {
		t.Fatal(err)
	}
	s := New(io.Discard, InitOptions{SessionsDir: "/tmp/sessions"})
	const uri = "file:///tmp/sessions/a/session.md"
	for _, tc := range []struct {
		name, text string
		line, char int
		scratch    bool
		incomplete bool
		firstLabel string
	}{
		{"bare at", "# @user\n@", 1, 1, false, true, "nested/"},
		{"query", "# @user\nsee @sess", 1, 9, false, true, "nested/sessions.go"},
		{"no file matches", "# @user\n@missing", 1, 8, false, true, ""},
		{"role", "# @u", 0, 4, false, false, "user"},
		{"frontmatter", "---\n@\n---", 1, 1, false, false, ""},
		{"email", "# @user\nme@sess", 1, 7, false, false, ""},
		{"before at", "# @user\n@", 1, 0, false, false, ""},
		{"scratch bare at", "@", 0, 1, true, true, "nested/"},
		{"scratch query", "see @sess", 0, 9, true, true, "nested/sessions.go"},
		{"scratch heading", "# @st", 0, 5, true, false, "steer"},
	} {
		t.Run(tc.name, func(t *testing.T) {
			s.docs[uri] = &docState{text: tc.text, cwd: cwd, scratch: tc.scratch}
			p := completionParams{Position: position{Line: tc.line, Character: tc.char}}
			p.TextDocument.URI = uri
			res := s.completionFor(p).(map[string]any)
			if res["isIncomplete"] != tc.incomplete {
				t.Fatalf("isIncomplete = %v, want %t", res["isIncomplete"], tc.incomplete)
			}
			items := res["items"].([]completionItem)
			if items == nil || (tc.firstLabel == "" && len(items) != 0) ||
				(tc.firstLabel != "" && (len(items) == 0 || items[0].Label != tc.firstLabel)) {
				t.Fatalf("items = %+v, want non-nil list with first label %q (empty if blank)", items, tc.firstLabel)
			}
		})
	}
}

func TestMessagesRequestServesGoConversion(t *testing.T) {
	uri := "file:///tmp/sessions/a/renamed-transcript.md"
	text := "# @user\nhello\n# @assistant\nreply\n"
	send := func(in *bytes.Buffer, v any) { in.Write(frame(v)) }

	var in bytes.Buffer
	send(&in, map[string]any{
		"jsonrpc": "2.0", "id": 1, "method": "initialize",
		"params": map[string]any{
			"initializationOptions": map[string]any{"sessions_dir": "/tmp/sessions"},
		},
	})
	send(&in, map[string]any{
		"jsonrpc": "2.0", "method": "textDocument/didOpen",
		"params": map[string]any{"textDocument": map[string]any{"uri": uri, "version": 1, "text": text}},
	})
	send(&in, map[string]any{"jsonrpc": "2.0", "id": 2, "method": "yap/messages", "params": map[string]any{
		"textDocument": map[string]any{"uri": uri},
	}})
	send(&in, map[string]any{"jsonrpc": "2.0", "id": 3, "method": "shutdown"})
	send(&in, map[string]any{"jsonrpc": "2.0", "method": "exit"})

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
		var msgs []document.Message
		if err := json.Unmarshal(resp.Result, &msgs); err != nil {
			t.Fatalf("messages result: %v (%s)", err, resp.Result)
		}
		if len(msgs) != 2 || msgs[0].Content != "hello" || msgs[1].Content != "reply" {
			t.Fatalf("messages = %+v", msgs)
		}
		return
	}
	t.Fatal("no yap/messages response")
}

// TestFileCompletionFiltersTypedPrefix pins the @path completion contract the
// client relies on: the edit replaces the text after the `@` (so the client's
// completion start column is the path itself) and filterText carries the same
// path, which is what makes typing `@fla` narrow to flake.nix.
func TestFileCompletionFiltersTypedPrefix(t *testing.T) {
	dir := t.TempDir()
	for _, name := range []string{"flake.nix", "flake.lock", "readme.md"} {
		if err := os.WriteFile(filepath.Join(dir, name), []byte("x"), 0o600); err != nil {
			t.Fatal(err)
		}
	}
	text := "# @user\n@fla\n"
	items := Completion(text, 1, 4, CompletionCtx{Cwd: dir})
	var labels []string
	for _, it := range items {
		labels = append(labels, it.Label)
		if it.FilterText != it.Label {
			t.Fatalf("filterText = %q, want %q", it.FilterText, it.Label)
		}
		if strings.HasPrefix(it.TextEdit.NewText, "@") {
			t.Fatalf("newText must not re-insert the @: %q", it.TextEdit.NewText)
		}
		if it.TextEdit.Range.Start.Character != 1 {
			t.Fatalf("edit starts at %d, want 1 (after the @)", it.TextEdit.Range.Start.Character)
		}
	}
	if strings.Join(labels, ",") != "flake.lock,flake.nix" {
		t.Fatalf("labels = %v, want the two flake files", labels)
	}
}
