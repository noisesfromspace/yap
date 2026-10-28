package lsp

import (
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
	symFunction = 12
	symVariable = 13
	symObject   = 19

	complModule     = 9
	complKeyword    = 14
	complFile       = 17
	complField      = 5
	complFunction   = 3
	complValue      = 12
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
// frontmatter, then one symbol per message with its regions as children.
func Symbols(text string) []symbol {
	doc := document.Parse(text)
	lines := doc.Lines

	var out []symbol
	if doc.Frontmatter > 0 {
		out = append(out, frontmatterSymbol(lines, doc.Frontmatter))
	}

	ri := 0
	for i, h := range doc.Headings {
		next := len(lines) // exclusive 0-based end of this message
		if i+1 < len(doc.Headings) {
			next = doc.Headings[i+1].Line - 1
		}
		if next < h.Line-1 {
			next = h.Line - 1
		}
		sym := symbol{
			Name:           messageName(lines, h),
			Kind:           symObject,
			Range:          rng{Start: position{Line: h.Line - 1}, End: position{Line: next}},
			SelectionRange: rng{Start: position{Line: h.Line - 1}, End: position{Line: h.Line}},
		}
		for ri < len(doc.Regions) && doc.Regions[ri].Start < h.Line {
			ri++
		}
		for ri < len(doc.Regions) && doc.Regions[ri].Start <= next {
			sym.Children = append(sym.Children, regionSymbol(lines, doc.Regions[ri], next))
			ri++
		}
		out = append(out, sym)
	}
	return out
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

func messageName(lines []string, h document.Heading) string {
	limit := h.Line + 5
	if limit > len(lines) {
		limit = len(lines)
	}
	for i := h.Line; i < limit; i++ {
		t := strings.TrimSpace(lines[i])
		if t != "" && !strings.HasPrefix(t, "<!-- yap:") {
			return h.Role + ": " + truncate(t, 60)
		}
	}
	return h.Role
}

func regionSymbol(lines []string, r document.Region, msgEnd int) symbol {
	start := r.Start - 1
	end := r.Finish
	if end == 0 {
		end = msgEnd
	}
	if end < start {
		end = start
	}
	return symbol{
		Name:           regionName(lines, r),
		Kind:           regionKind(r.Kind),
		Range:          rng{Start: position{Line: start}, End: position{Line: end}},
		SelectionRange: rng{Start: position{Line: start}, End: position{Line: start + 1}},
	}
}

func regionKind(kind string) int {
	if kind == "tool" {
		return symFunction
	}
	return symVariable
}

func regionName(lines []string, r document.Region) string {
	if r.Kind != "tool" {
		return r.Kind
	}
	if h := document.DecodeToolHeader(lines, r); h != nil && h.Name != "" {
		return "tool: " + h.Name
	}
	return "tool"
}

// ─── Completion ─────────────────────────────────────────────────────────────

// CompletionCtx carries editor-owned context the server cannot derive from the
// document itself.
type CompletionCtx struct {
	Cwd       string
	AgentsDir string
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
	{"title", "text", "display title"},
	{"description", "text", "generated summary"},
	{"model", "model", "model id"},
	{"provider", "provider", "provider name"},
	{"reasoning_level", "enum", "low, medium or high"},
	{"created_cwd", "text", "creation working directory"},
	{"agent", "agent", "subagent definition"},
	{"turns", "int", "completed replies"},
	{"created_at", "text", "creation timestamp"},
	{"updated_at", "text", "last write timestamp"},
	{"models", "combos", "combo history"},
	{"forked_from", "text", "fork source"},
	{"subagent_parent", "text", "owner session"},
	{"subagents", "list", "subagent session paths"},
	{"forks", "list", "forked session paths"},
	{"tools", "tools", "tool allowlist"},
}

var reasoningLevels = []string{"low", "medium", "high"}
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
	case "enum":
		return fixedCompletions(reasoningLevels, complValue, r)
	case "provider":
		return providerCompletion(r)
	case "agent":
		return agentCompletion(ctx.AgentsDir, r)
	case "tools":
		return toolCompletion(r)
	case "model":
		return modelCompletion(provider, r)
	case "combos":
		return combosCompletion(r)
	}
	return nil
}

func listValueCompletion(key string, startCol, char, line int, ctx CompletionCtx) []completionItem {
	r := rng{Start: position{Line: line, Character: startCol}, End: position{Line: line, Character: char}}
	switch key {
	case "tools":
		return toolCompletion(r)
	case "models":
		return combosCompletion(r)
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

func modelCompletion(provider string, r rng) []completionItem {
	var names []string
	for _, combo := range loadModelsCache() {
		if provider == "" {
			names = append(names, combo)
		} else if rest, ok := strings.CutPrefix(combo, provider+"/"); ok {
			names = append(names, rest)
		}
	}
	return fixedCompletions(names, complValue, r)
}

func combosCompletion(r rng) []completionItem {
	return fixedCompletions(loadModelsCache(), complValue, r)
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
	if wordStart <= 0 || wordStart >= len(cur) || cur[wordStart] != '@' {
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
	for _, p := range paths {
		if !strings.HasPrefix(p, afterAt) {
			continue
		}
		if seen[p] {
			continue
		}
		seen[p] = true
		ref := "@" + p
		if strings.Contains(p, " ") {
			ref = `@"` + p + `"`
		}
		out = append(out, completionItem{
			Label:      p,
			Kind:       complFile,
			SortText:   p,
			InsertText: ref,
			TextEdit:   &textEdit{Range: rng{Start: position{Line: line, Character: wordStart}, End: position{Line: line, Character: char}}, NewText: ref},
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
	doc := document.Parse(text)
	var out []diagnostic
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
		case "reasoning_level":
			if val != "" && !containsString(reasoningLevels, val) {
				out = append(out, diagnostic{
					Range:    lineRange(lines, i),
					Severity: sevWarning,
					Source:   "yap",
					Message:  "reasoning_level must be low, medium or high",
				})
			}
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

func loadModelsCache() []string {
	dir, err := os.UserCacheDir()
	if err != nil {
		return nil
	}
	b, err := os.ReadFile(filepath.Join(dir, "yap", "models"))
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

// listUnder lists files under root (bounded depth/result count), filtered to
// those whose relative path starts with prefix. Directories are returned with
// a trailing slash so the client can complete further segments.
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
	base := root
	if prefix != "" {
		base = filepath.Join(root, filepath.Dir(prefix))
	}
	walk(base, "", 0)
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
