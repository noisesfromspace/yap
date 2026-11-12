package lsp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"unicode/utf8"

	"boers.email/yap/agent/config"
	"boers.email/yap/agent/document"
	"boers.email/yap/agent/tools"
)

// ─── Shared LSP result types ───────────────────────────────────────────────

type symbol struct {
	Name           string   `json:"name"`
	Kind           int      `json:"kind"`
	Range          rng      `json:"range"`
	SelectionRange rng      `json:"selectionRange"`
	Children       []symbol `json:"children,omitempty"`
}

type completionItem struct {
	Label      string    `json:"label"`
	Kind       int       `json:"kind,omitempty"`
	Detail     string    `json:"detail,omitempty"`
	SortText   string    `json:"sortText,omitempty"`
	FilterText string    `json:"filterText,omitempty"`
	InsertText string    `json:"insertText,omitempty"`
	TextEdit   *textEdit `json:"textEdit,omitempty"`
}

type textEdit struct {
	Range   rng    `json:"range"`
	NewText string `json:"newText"`
}

type diagnostic struct {
	Range    rng    `json:"range"`
	Severity int    `json:"severity,omitempty"`
	Source   string `json:"source,omitempty"`
	Message  string `json:"message"`
}

// LSP SymbolKind / CompletionItemKind constants used here.
const (
	symStruct   = 23
	symVariable = 13
	symObject   = 19

	complModule   = 9
	complKeyword  = 14
	complFile     = 17
	complField    = 5
	complFunction = 3
	complValue    = 12
)

// LSP DiagnosticSeverity.
const sevWarning = 2

// ─── Incremental text sync (UTF-16) ────────────────────────────────────────

// applyChange applies one range-based content change to text, converting
// UTF-16 character offsets to byte offsets.
func applyChange(text string, ch changeEvent) string {
	start := positionToByte(text, ch.Range.Start)
	end := positionToByte(text, ch.Range.End)
	if start < 0 {
		start = 0
	}
	if end < start {
		end = start
	}
	if end > len(text) {
		end = len(text)
	}
	return text[:start] + ch.Text + text[end:]
}

// positionToByte returns the byte offset of a 0-based (line, utf16 character)
// position in text.
func positionToByte(text string, p position) int {
	offset := 0
	for i := 0; i < p.Line && offset < len(text); i++ {
		nl := strings.IndexByte(text[offset:], '\n')
		if nl < 0 {
			return len(text)
		}
		offset += nl + 1
	}
	rest := text[offset:]
	if end := strings.IndexByte(rest, '\n'); end >= 0 {
		rest = rest[:end]
	}
	return offset + utf16ColToByte(rest, p.Character)
}

func utf16ColToByte(s string, col int) int {
	b := 0
	u := 0
	for b < len(s) {
		r, size := utf8.DecodeRuneInString(s[b:])
		ru := 1
		if r >= 0x10000 {
			ru = 2
		}
		if u+ru > col {
			break
		}
		u += ru
		b += size
		if u == col {
			break
		}
	}
	return b
}

// ─── Document symbols ──────────────────────────────────────────────────────

// Symbols returns the document-symbol outline of a session transcript:
// one symbol per message, newest first, then the frontmatter block at the
// bottom. Tool calls, thinking and other machine regions are display-only
// and never appear in the outline, except subagent tool calls, which nest
// under their enclosing message as children; empty messages are dropped, and
// a turn that only ran tools and then failed names itself by its error.
func Symbols(text string) []symbol {
	return symbolsFromDoc(document.Parse(text))
}

// symbolsFromDoc is Symbols over an already-parsed document, so a caller that
// holds a cached parse does not re-scan the transcript.
func symbolsFromDoc(doc *document.Document) []symbol {
	lines := doc.Lines

	// Machine regions (tool, thinking, error, …) never become symbols, and
	// their body lines must not leak into a message's preview name. The one
	// exception is a subagent tool call, which becomes a child of the message
	// that invoked it.
	hidden := machineLines(lines, doc.Regions)
	errored := errorLines(lines, doc.Regions)
	subagents := subagentCalls(doc)

	var out []symbol
	// Messages newest first: the most recent conversation sits at the top of
	// the outline, matching how a live transcript reads bottom-up.
	for i := len(doc.Headings) - 1; i >= 0; i-- {
		h := doc.Headings[i]
		next := len(lines) // exclusive 0-based end of this message
		if i+1 < len(doc.Headings) {
			next = doc.Headings[i+1].Line - 1
		}
		if next < h.Line-1 {
			next = h.Line - 1
		}
		name := messageName(lines, h, hidden, errored, next)
		children := subagents[i]
		if name == "" && len(children) == 0 {
			continue // empty message: nothing to navigate to
		}
		if name == "" {
			name = h.Role + ": subagent"
		}
		out = append(out, symbol{
			Name:           name,
			Kind:           symObject,
			Range:          rng{Start: position{Line: h.Line - 1}, End: position{Line: next}},
			SelectionRange: rng{Start: position{Line: h.Line - 1}, End: position{Line: h.Line}},
			Children:       children,
		})
	}
	if doc.Frontmatter > 0 {
		out = append(out, frontmatterSymbol(lines, doc.Frontmatter))
	}
	return out
}

// subagentCalls returns one child symbol per subagent tool call, grouped by
// the index of the heading whose message contains the call. Other tool calls
// stay display-only and are omitted.
func subagentCalls(doc *document.Document) [][]symbol {
	out := make([][]symbol, len(doc.Headings))
	hi := 0
	for _, r := range doc.Regions {
		if r.Kind != "tool" {
			continue
		}
		h := document.DecodeToolHeader(doc.Lines, r)
		if h == nil || h.Name != "subagent" {
			continue
		}
		for hi < len(doc.Headings) && doc.Headings[hi].Line <= r.Start {
			hi++
		}
		idx := hi - 1
		if idx < 0 {
			continue // subagent before the first heading: not part of a message
		}
		out[idx] = append(out[idx], subagentSymbol(r, h))
	}
	return out
}

func subagentSymbol(r document.Region, h *document.ToolHeader) symbol {
	start := r.Start
	end := r.Finish
	if end < start {
		end = start
	}
	return symbol{
		Name:           subagentName(h),
		Kind:           symObject,
		Range:          rng{Start: position{Line: start - 1}, End: position{Line: end}},
		SelectionRange: rng{Start: position{Line: start - 1}, End: position{Line: start}},
	}
}

// subagentName derives a subagent symbol's display name from its arguments,
// mirroring the session picker's "agent · task" subagent label.
func subagentName(h *document.ToolHeader) string {
	var args struct {
		Agent string `json:"agent"`
		Task  string `json:"task"`
	}
	if h.Arguments != nil {
		_ = json.Unmarshal(h.Arguments, &args)
	}
	switch {
	case args.Agent == "" && args.Task == "":
		return "subagent"
	case args.Agent == "":
		return "subagent: " + truncate(args.Task, 60)
	case args.Task == "":
		return args.Agent
	default:
		return args.Agent + " · " + truncate(args.Task, 60)
	}
}

// machineLines marks every line inside a machine region (tool, thinking,
// error, …). Those bodies are display-only: excluded from the symbol outline
// and from the preview name a message symbol derives from its first visible
// prose line.
func machineLines(lines []string, regions []document.Region) []bool {
	hidden := make([]bool, len(lines))
	for _, r := range regions {
		hi := r.Finish
		if hi == 0 || hi > len(lines) {
			hi = len(lines)
		}
		if hi < r.Start {
			hi = r.Start
		}
		for ln := r.Start - 1; ln < hi && ln < len(lines); ln++ {
			hidden[ln] = true
		}
	}
	return hidden
}

// errorLines marks the body lines of error regions (between the `<!--
// yap:error` opener and its `-->` closer). A message with no visible prose
// names itself by the first of these, so a failed turn is still reachable.
func errorLines(lines []string, regions []document.Region) []bool {
	errored := make([]bool, len(lines))
	for _, r := range regions {
		if r.Kind != "error" {
			continue
		}
		finish := r.Finish
		if finish == 0 || finish > len(lines) {
			finish = len(lines)
		}
		if finish < r.Start {
			finish = r.Start
		}
		// Body only: r.Start is the 1-based opener, r.Finish the 1-based
		// closer; the body sits strictly between them (0-based [r.Start,
		// r.Finish-1)).
		for ln := r.Start; ln < finish-1 && ln < len(lines); ln++ {
			errored[ln] = true
		}
	}
	return errored
}

func frontmatterSymbol(lines []string, close int) symbol {
	s := symbol{
		Name:           "frontmatter",
		Kind:           symStruct,
		Range:          rng{Start: position{}, End: position{Line: close}},
		SelectionRange: rng{Start: position{}, End: position{Line: 1}},
	}
	for i := 1; i < close-1 && i < len(lines); i++ {
		if k, _ := splitLineKey(lines[i]); k != "" {
			s.Children = append(s.Children, symbol{
				Name:           k,
				Kind:           symVariable,
				Range:          rng{Start: position{Line: i}, End: position{Line: i + 1}},
				SelectionRange: rng{Start: position{Line: i}, End: position{Line: i + 1}},
			})
		}
	}
	return s
}

// messageName derives a message symbol's display name from its first visible
// prose line. A message whose body is only machine regions (a turn that ran
// tools and then failed) falls back to the first error line; a message with no
// content at all returns "", which the caller drops from the outline.
func messageName(lines []string, h document.Heading, hidden, errored []bool, end int) string {
	for i := h.Line; i < end; i++ {
		t := strings.TrimSpace(lines[i])
		if t == "" || strings.HasPrefix(t, "<!-- yap:") || hidden[i] {
			continue
		}
		return h.Role + ": " + truncate(t, 60)
	}
	for i := h.Line; i < end; i++ {
		if errored[i] {
			if t := strings.TrimSpace(lines[i]); t != "" {
				return h.Role + ": " + truncate(t, 60)
			}
		}
	}
	return ""
}

// ─── Completion ─────────────────────────────────────────────────────────────

// CompletionCtx carries editor-owned context the server cannot derive from the
// document itself.
type CompletionCtx struct {
	Cwd         string
	AgentsDir   string
	ModelsCache string
}

// Completion returns completion items for the cursor position.
func Completion(text string, line, char int, ctx CompletionCtx) []completionItem {
	lines := strings.Split(text, "\n")
	if line < 0 || line >= len(lines) {
		return nil
	}
	cur := lines[line]
	if char < 0 {
		char = 0
	}
	if char > len(cur) {
		char = len(cur)
	}
	prefix := cur[:char]
	wordStart := char
	for wordStart > 0 && isWordChar(cur[wordStart-1]) {
		wordStart--
	}
	word := cur[wordStart:char]

	if close := frontmatterClose(lines); close > 0 && line > 0 && line < close {
		return frontmatterCompletion(lines, line, prefix, wordStart, char, ctx)
	}
	if items, ok := roleCompletion(cur, char, line); ok {
		return items
	}
	if isFileRef(cur, wordStart) {
		return fileCompletion(ctx.Cwd, word, line, wordStart, char)
	}
	return nil
}

// ScratchCompletion offers file references and the scratch's two control
// headings, without treating the scratch as a transcript.
func ScratchCompletion(text string, line, char int, cwd string) []completionItem {
	lines := strings.Split(text, "\n")
	if line < 0 || line >= len(lines) {
		return nil
	}
	cur := lines[line]
	if char < 0 {
		char = 0
	}
	if char > len(cur) {
		char = len(cur)
	}
	if strings.HasPrefix(cur, "# @") && char >= 3 && allLetters(cur[3:]) {
		partial := cur[3:char]
		r := rng{Start: position{Line: line, Character: 3}, End: position{Line: line, Character: len(cur)}}
		var items []completionItem
		for _, role := range []string{"steer", "queue"} {
			if strings.HasPrefix(role, partial) {
				items = append(items, completionItem{Label: role, Kind: complKeyword, TextEdit: &textEdit{Range: r, NewText: role}})
			}
		}
		return items
	}
	wordStart := char
	for wordStart > 0 && isWordChar(cur[wordStart-1]) {
		wordStart--
	}
	if isFileRef(cur, wordStart) {
		return fileCompletion(cwd, cur[wordStart:char], line, wordStart, char)
	}
	return nil
}

// ─── Frontmatter completion ────────────────────────────────────────────────

type fieldDef struct {
	name   string
	kind   string // "text" | "enum" | "list" | "int" | "provider" | "model" | "agent" | "tools" | "combos"
	detail string
}

// fields is the Go-owned inventory of frontmatter keys (used for completion
// and validation). Lua's frontmatter.lua remains the buffer writer; this list
// is the canonical set for language services.
var fields = []fieldDef{
	{"description", "text", "generated summary"},
	{"model", "model", "model id"},
	{"provider", "provider", "provider name"},
	{"created_cwd", "text", "creation working directory"},
	{"data_dir", "text", "session data directory"},
	{"agent", "agent", "subagent definition"},
	{"turns", "int", "completed replies"},
	{"created_at", "text", "creation timestamp"},
	{"updated_at", "text", "last write timestamp"},
	{"models", "combos", "combo history"},
	{"forked_from", "text", "fork source directory"},
	{"subagent_parent", "text", "owner session directory"},
	{"tools", "tools", "tool allowlist"},
}

var roles = []string{"user", "assistant", "system"}

func frontmatterCompletion(lines []string, line int, prefix string, wordStart, char int, ctx CompletionCtx) []completionItem {
	if strings.Contains(prefix, ":") {
		key, valStart := splitKeyValue(prefix)
		provider := frontmatterProvider(lines)
		for _, f := range fields {
			if f.name == key {
				return fieldValueCompletion(f, valStart, char, line, provider, ctx)
			}
		}
		return nil
	}
	if isListItem(prefix) {
		key := listKeyAbove(lines, line)
		return listValueCompletion(key, wordStart, char, line, ctx)
	}
	return fieldKeyCompletion(lines, line, wordStart, char, strings.TrimSpace(prefix))
}

// splitKeyValue returns the key and the 0-based column where the value starts
// in s (for a `key: value` line).
func splitKeyValue(s string) (string, int) {
	i := strings.Index(s, ":")
	if i < 0 {
		return "", 0
	}
	j := i + 1
	for j < len(s) && isSpace(s[j]) {
		j++
	}
	return strings.TrimSpace(s[:i]), j
}

func isListItem(s string) bool {
	t := strings.TrimLeft(s, " \t")
	return strings.HasPrefix(t, "-")
}

// listKeyAbove finds the list field a list item belongs to by scanning upward.
func listKeyAbove(lines []string, line int) string {
	for i := line - 1; i >= 1; i-- {
		k, _ := splitLineKey(lines[i])
		if k != "" {
			return k
		}
	}
	return ""
}

func frontmatterProvider(lines []string) string {
	close := frontmatterClose(lines)
	if close == 0 {
		return ""
	}
	for i := 1; i < close && i < len(lines); i++ {
		k, v := splitLineKey(lines[i])
		if k == "provider" {
			return v
		}
	}
	return ""
}

func fieldKeyCompletion(lines []string, line, wordStart, char int, partial string) []completionItem {
	existing := map[string]bool{}
	if close := frontmatterClose(lines); close > 0 {
		for i := 1; i < close && i < len(lines); i++ {
			if k, _ := splitLineKey(lines[i]); k != "" {
				existing[k] = true
			}
		}
	}
	r := rng{Start: position{Line: line, Character: wordStart}, End: position{Line: line, Character: char}}
	var out []completionItem
	for _, f := range fields {
		if existing[f.name] {
			continue
		}
		if !strings.HasPrefix(f.name, partial) {
			continue
		}
		out = append(out, completionItem{
			Label:    f.name,
			Kind:     complField,
			Detail:   f.detail,
			SortText: f.name,
			TextEdit: &textEdit{Range: r, NewText: f.name},
		})
	}
	return out
}

func fieldValueCompletion(f fieldDef, startCol, char, line int, provider string, ctx CompletionCtx) []completionItem {
	r := rng{Start: position{Line: line, Character: startCol}, End: position{Line: line, Character: char}}
	switch f.kind {
	case "provider":
		return providerCompletion(r)
	case "agent":
		return agentCompletion(ctx.AgentsDir, r)
	case "tools":
		return toolCompletion(r)
	case "model":
		return modelCompletion(provider, ctx.ModelsCache, r)
	case "combos":
		return combosCompletion(ctx.ModelsCache, r)
	}
	return nil
}

func listValueCompletion(key string, startCol, char, line int, ctx CompletionCtx) []completionItem {
	r := rng{Start: position{Line: line, Character: startCol}, End: position{Line: line, Character: char}}
	switch key {
	case "tools":
		return toolCompletion(r)
	case "models":
		return combosCompletion(ctx.ModelsCache, r)
	case "agent":
		return agentCompletion(ctx.AgentsDir, r)
	}
	return nil
}

func fixedCompletions(values []string, kind int, r rng) []completionItem {
	out := make([]completionItem, 0, len(values))
	for _, v := range values {
		out = append(out, completionItem{Label: v, Kind: kind, SortText: v, TextEdit: &textEdit{Range: r, NewText: v}})
	}
	return out
}

func providerCompletion(r rng) []completionItem {
	cfg, err := config.LoadConfig()
	if err != nil {
		return nil
	}
	var names []string
	for n := range cfg.Providers {
		names = append(names, n)
	}
	sort.Strings(names)
	return fixedCompletions(names, complValue, r)
}

func toolCompletion(r rng) []completionItem {
	var names []string
	for _, t := range tools.All() {
		names = append(names, t.Name)
	}
	return fixedCompletions(names, complFunction, r)
}

func agentCompletion(agentsDir string, r rng) []completionItem {
	return fixedCompletions(listAgentStems(agentsDir), complModule, r)
}

func modelCompletion(provider, cachePath string, r rng) []completionItem {
	var names []string
	for _, combo := range loadModelsCache(cachePath) {
		if provider == "" {
			names = append(names, combo)
		} else if rest, ok := strings.CutPrefix(combo, provider+"/"); ok {
			names = append(names, rest)
		}
	}
	return fixedCompletions(names, complValue, r)
}

func combosCompletion(cachePath string, r rng) []completionItem {
	return fixedCompletions(loadModelsCache(cachePath), complValue, r)
}

// ─── Role completion ───────────────────────────────────────────────────────

func roleCompletion(cur string, char, line int) ([]completionItem, bool) {
	if !strings.HasPrefix(cur, "# @") {
		return nil, false
	}
	rest := cur[len("# @"):]
	if char < len("# @") || !allLetters(rest) {
		return nil, false
	}
	partial := ""
	if char-len("# @") <= len(rest) {
		partial = rest[:char-len("# @")]
	}
	r := rng{
		Start: position{Line: line, Character: len("# @")},
		End:   position{Line: line, Character: len("# @") + len(rest)},
	}
	var out []completionItem
	for _, role := range roles {
		if strings.HasPrefix(role, partial) {
			out = append(out, completionItem{Label: role, Kind: complKeyword, SortText: role, TextEdit: &textEdit{Range: r, NewText: role}})
		}
	}
	return out, true
}

// ─── File reference completion ─────────────────────────────────────────────

func isFileRef(cur string, wordStart int) bool {
	// wordStart 0 means the reference begins the line (a fresh message body
	// starts with `@`), which is a valid reference position. Only reject a
	// negative start (no word) or a start past the end (empty line).
	if wordStart < 0 || wordStart >= len(cur) || cur[wordStart] != '@' {
		return false
	}
	return wordStart == 0 || isSpace(cur[wordStart-1])
}

func fileCompletion(cwd, word string, line, wordStart, char int) []completionItem {
	if cwd == "" {
		return nil
	}
	afterAt := strings.TrimPrefix(word, "@")
	paths := listUnder(cwd, afterAt)
	seen := map[string]bool{}
	var out []completionItem
	// The inserted text replaces everything AFTER the `@`, which the client
	// leaves in place. That keeps the completion start column at the path
	// itself, so Neovim filters on what the user typed ("fla" against
	// "flake.nix") instead of against a prefixed "@fla".
	start := wordStart + 1
	if start > char {
		start = char
	}
	for _, p := range paths {
		if !strings.HasPrefix(p, afterAt) {
			continue
		}
		if seen[p] {
			continue
		}
		seen[p] = true
		insert := p
		if strings.Contains(p, " ") {
			insert = `"` + p + `"`
		}
		out = append(out, completionItem{
			Label:      p,
			Kind:       complFile,
			SortText:   p,
			FilterText: p,
			InsertText: insert,
			TextEdit:   &textEdit{Range: rng{Start: position{Line: line, Character: start}, End: position{Line: line, Character: char}}, NewText: insert},
		})
		if len(out) >= 200 {
			break
		}
	}
	return out
}

// ─── Diagnostics ───────────────────────────────────────────────────────────

// Diagnostics validates a session transcript. It tolerates unknown frontmatter
// keys, adjacent same-role messages and historical tool/model names, and it
// suppresses incomplete-tail diagnostics while a reply is streaming.
func Diagnostics(text string, streaming bool) []diagnostic {
	return diagnosticsFromDoc(document.Parse(text), streaming)
}

// diagnosticsFromDoc is Diagnostics over an already-parsed document.
func diagnosticsFromDoc(doc *document.Document, streaming bool) []diagnostic {
	// Start non-nil: LSP requires publishDiagnostics.diagnostics to be an
	// array, and a nil slice would marshal to `null`, which Neovim decodes
	// as vim.NIL and chokes on (#diagnostics on a userdata).
	out := []diagnostic{}
	out = append(out, frontmatterDiagnostics(doc)...)
	out = append(out, headingDiagnostics(doc)...)
	out = append(out, toolHeaderDiagnostics(doc)...)
	if !streaming {
		out = append(out, unclosedRegionDiagnostics(doc)...)
	}
	return out
}

func frontmatterDiagnostics(doc *document.Document) []diagnostic {
	lines := doc.Lines
	if len(lines) == 0 {
		return nil
	}
	var out []diagnostic
	if strings.TrimSpace(lines[0]) == "---" && doc.Frontmatter == 0 {
		out = append(out, diagnostic{
			Range:    lineRange(lines, 0),
			Severity: sevWarning,
			Source:   "yap",
			Message:  "frontmatter is unterminated: add a closing `---`",
		})
		return out
	}
	if doc.Frontmatter == 0 {
		return nil
	}
	close := doc.Frontmatter - 1 // 0-based closing line
	seen := map[string]int{}
	for i := 1; i < close && i < len(lines); i++ {
		key, val := splitLineKey(lines[i])
		if key == "" {
			continue
		}
		if prev, dup := seen[key]; dup {
			out = append(out, diagnostic{
				Range:    lineRange(lines, i),
				Severity: sevWarning,
				Source:   "yap",
				Message:  "duplicate frontmatter key " + key + " (first at line " + strconv.Itoa(prev+1) + ")",
			})
		} else {
			seen[key] = i
		}
		switch key {
		case "turns":
			if val != "" && !allDigits(val) {
				out = append(out, diagnostic{
					Range:    lineRange(lines, i),
					Severity: sevWarning,
					Source:   "yap",
					Message:  "turns must be a number",
				})
			}
		}
	}
	return out
}

func headingDiagnostics(doc *document.Document) []diagnostic {
	var out []diagnostic
	for _, h := range doc.Headings {
		if h.Role != "system" && h.Role != "user" && h.Role != "assistant" {
			out = append(out, diagnostic{
				Range:    lineRange(doc.Lines, h.Line-1),
				Severity: sevWarning,
				Source:   "yap",
				Message:  "unknown message role " + h.Role + " (expected system, user or assistant)",
			})
		}
	}
	return out
}

func toolHeaderDiagnostics(doc *document.Document) []diagnostic {
	var out []diagnostic
	for _, r := range doc.Regions {
		if r.Kind != "tool" || r.HeaderFinish == 0 {
			continue
		}
		if h := document.DecodeToolHeader(doc.Lines, r); h == nil || h.Name == "" {
			out = append(out, diagnostic{
				Range:    regionRange(doc.Lines, r),
				Severity: sevWarning,
				Source:   "yap",
				Message:  "malformed yap:tool header: expected JSON with id and name",
			})
		}
	}
	return out
}

func unclosedRegionDiagnostics(doc *document.Document) []diagnostic {
	var out []diagnostic
	for _, r := range doc.Regions {
		if r.Finish != 0 && !r.Unclosed {
			continue
		}
		out = append(out, diagnostic{
			Range:    regionRange(doc.Lines, r),
			Severity: sevWarning,
			Source:   "yap",
			Message:  "unclosed " + r.Kind + " region",
		})
	}
	return out
}

// ─── Helpers ───────────────────────────────────────────────────────────────

func lineRange(lines []string, idx int) rng {
	if idx < 0 || idx >= len(lines) {
		return rng{}
	}
	end := len(lines[idx])
	return rng{Start: position{Line: idx}, End: position{Line: idx, Character: end}}
}

func regionRange(lines []string, r document.Region) rng {
	start := r.Start - 1
	end := r.Finish - 1
	if end < start {
		end = start
	}
	if end >= len(lines) {
		end = len(lines) - 1
	}
	last := 0
	if end >= 0 {
		last = len(lines[end])
	}
	return rng{Start: position{Line: start}, End: position{Line: end, Character: last}}
}

// splitLineKey returns the top-level key and value of a frontmatter line, or
// ("","") for a non-key line (list item, blank, comment, `---`).
func splitLineKey(line string) (string, string) {
	i := strings.Index(line, ":")
	if i <= 0 {
		return "", ""
	}
	key := strings.TrimSpace(line[:i])
	if key == "" || strings.ContainsAny(key, " \t") {
		return "", ""
	}
	if line[0] == ' ' || line[0] == '\t' || line[0] == '-' {
		return "", ""
	}
	return key, strings.TrimSpace(line[i+1:])
}

func frontmatterClose(lines []string) int {
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return 0
	}
	limit := len(lines)
	if limit > 200 {
		limit = 200
	}
	for i := 1; i < limit; i++ {
		if strings.TrimSpace(lines[i]) == "---" {
			return i
		}
	}
	return 0
}

func loadModelsCache(path string) []string {
	if path == "" {
		dir, err := os.UserCacheDir()
		if err != nil {
			return nil
		}
		path = filepath.Join(dir, "yap", "models")
	}
	b, err := os.ReadFile(path)
	if err != nil {
		return nil
	}
	var out []string
	for _, line := range strings.Split(string(b), "\n") {
		line = strings.TrimSpace(line)
		if line != "" {
			out = append(out, line)
		}
	}
	return out
}

func listAgentStems(agentsDir string) []string {
	if agentsDir == "" {
		return nil
	}
	entries, err := os.ReadDir(agentsDir)
	if err != nil {
		return nil
	}
	var out []string
	for _, e := range entries {
		if e.IsDir() || filepath.Ext(e.Name()) != ".md" {
			continue
		}
		out = append(out, strings.TrimSuffix(e.Name(), ".md"))
	}
	sort.Strings(out)
	return out
}

// listUnder lists files under root (bounded depth/result count) as paths
// relative to root. Paths are relative to root even when prefix names a
// subdirectory, so a caller filtering by prefix sees the whole relative path
// and can insert it verbatim. Directories carry a trailing slash so the client
// can complete further segments.
func listUnder(root, prefix string) []string {
	var out []string
	var walk func(dir, rel string, depth int)
	walk = func(dir, rel string, depth int) {
		if depth > 3 || len(out) >= 500 {
			return
		}
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		for _, e := range entries {
			if len(out) >= 500 {
				return
			}
			name := e.Name()
			relp := name
			if rel != "" {
				relp = rel + "/" + name
			}
			if e.IsDir() {
				if skipDir(name) {
					continue
				}
				out = append(out, relp+"/")
				walk(filepath.Join(dir, name), relp, depth+1)
			} else {
				out = append(out, relp)
			}
		}
	}
	walk(root, "", 0)
	sort.Strings(out)
	return out
}

func skipDir(name string) bool {
	switch name {
	case ".git", ".hg", ".svn", "node_modules", "vendor", "target", ".direnv", ".devenv":
		return true
	}
	return strings.HasPrefix(name, ".")
}

func truncate(s string, n int) string {
	r := []rune(s)
	if len(r) <= n {
		return s
	}
	return string(r[:n]) + "…"
}

func isWordChar(b byte) bool {
	return b == '_' || b == '-' || b == '.' || b == '@' || b == '/' ||
		(b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9')
}

func isSpace(b byte) bool {
	return b == ' ' || b == '\t'
}

func allLetters(s string) bool {
	for i := 0; i < len(s); i++ {
		c := s[i]
		if (c < 'a' || c > 'z') && (c < 'A' || c > 'Z') {
			return false
		}
	}
	return true
}

func allDigits(s string) bool {
	if s == "" {
		return false
	}
	for i := 0; i < len(s); i++ {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

func containsString(xs []string, s string) bool {
	for _, x := range xs {
		if x == s {
			return true
		}
	}
	return false
}
