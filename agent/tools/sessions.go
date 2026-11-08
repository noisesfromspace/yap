package tools

import (
	"bufio"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"time"

	"boers.email/yap/agent/document"
	"boers.email/yap/agent/utils"
	"boers.email/yap/agent/wire"
)

// The `sessions` tool reads OTHER saved sessions. It is deliberately scoped to
// the sessions root (utils.SessionsRoot, sent by the frontend with each turn),
// so a model in one conversation can discover, grep, and pull context from
// past conversations without knowing their on-disk layout — and without
// loading a huge transcript whole into the current context.

// listMax caps the number of sessions `list` returns, so a long-lived sessions
// root does not flood the context; the most recently modified come first.
const listMax = 50

type sessionsArgs struct {
	Action        string `json:"action" jsonschema:"description=what to do: list saved sessions, search all session text, or read one session (list|search|read)"`
	Pattern       string `json:"pattern,omitempty" jsonschema:"description=ripgrep pattern for action=search"`
	Path          string `json:"path,omitempty" jsonschema:"description=session transcript file or its directory for action=read; for action=list, scope to sessions under this directory"`
	Filter        string `json:"filter,omitempty" jsonschema:"description=case-insensitive substring matched against description/path/cwd/model for action=list"`
	Since         string `json:"since,omitempty" jsonschema:"description=only sessions modified on or after this date (YYYY-MM-DD or RFC3339) for action=list"`
	Until         string `json:"until,omitempty" jsonschema:"description=only sessions modified on or before this date (YYYY-MM-DD or RFC3339) for action=list"`
	Start         int    `json:"start,omitempty" jsonschema:"description=1-based message index to begin the prose at for action=read (default 1)"`
	Count         int    `json:"count,omitempty" jsonschema:"description=number of messages to include for action=read (default: all)"`
	IncludeSystem bool   `json:"include_system,omitempty" jsonschema:"description=include the # @system message prose for action=read (default false: it is skipped)"`
}

func init() {
	Register("sessions",
		"List, search, and read other saved Yap session transcripts under the sessions root. "+
			"Use it to find and reference past conversations instead of guessing their paths. "+
			"action=list names sessions with their description, cwd, model and turn count (most recent first, capped at 50); narrow with filter (substring), since/until (dates), or path (a project scope). "+
			"action=search greps every transcript's text (ripgrep, path:line:content) without loading them. "+
			"action=read prints one session's message outline plus its prose with tool/thinking regions dropped and its # @system message skipped unless include_system is set; "+
			"page with start/count and follow up with the read tool for raw lines. Search or outline first — never load a whole large session.",
		func(a *sessionsArgs) (string, string, error) {
			switch a.Action {
			case "list":
				return listSessions(a)
			case "search":
				return searchSessions(a.Pattern)
			case "read":
				return readSession(a)
			case "":
				return "", "", fmt.Errorf("sessions: action is required (list, search, read)")
			default:
				return "", "", fmt.Errorf("sessions: unknown action %q (want list, search, read)", a.Action)
			}
		})
}

// ─── list ──────────────────────────────────────────────────────────────────

// sessionTranscripts walks the sessions root and returns the transcript .md
// file for every session directory. A session directory is one that directly
// contains a transcript markdown file (any .md that is not notes.md); an
// assets/ working folder is never a session and is skipped. Mirrors
// lua/harness/path.lua::session_dirs.
func sessionTranscripts(root string) []string {
	var out []string
	var walk func(string)
	walk = func(dir string) {
		entries, err := os.ReadDir(dir)
		if err != nil {
			return
		}
		var subdirs []string
		for _, e := range entries {
			name := e.Name()
			if e.IsDir() {
				if name != "assets" {
					subdirs = append(subdirs, filepath.Join(dir, name))
				}
			} else if name != "notes.md" && strings.HasSuffix(name, ".md") {
				out = append(out, filepath.Join(dir, name))
				return // a session dir is a leaf; do not recurse into it
			}
		}
		for _, sub := range subdirs {
			walk(sub)
		}
	}
	walk(root)
	sort.Strings(out)
	return out
}

// sessionsScope resolves a `path` scope for list. A directory already under
// the sessions root is used as-is; an absolute path elsewhere is a project
// cwd, resolved to its slug subdirectory (mirrors lua/harness/path.lua: a
// leading "/" becomes "-", so `/opt/code/yap` → `-opt-code-yap`); a relative
// path is joined to the root.
func sessionsScope(root, p string) string {
	scope := filepath.Clean(utils.ExpandHome(p))
	if scope == "." || scope == "" {
		return root
	}
	if !filepath.IsAbs(scope) {
		return filepath.Join(root, scope)
	}
	if scope == root || strings.HasPrefix(scope, root+string(filepath.Separator)) {
		return scope
	}
	return filepath.Join(root, cwdSlug(scope))
}

// cwdSlug converts a project cwd to the slug directory name used under the
// sessions root. Mirrors lua/harness/path.lua::cwd_slug: every character that
// is not alphanumeric, `.`, `_`, or `-` becomes `-`.
func cwdSlug(cwd string) string {
	var b strings.Builder
	for _, r := range filepath.Clean(cwd) {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '.', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('-')
		}
	}
	return b.String()
}

// scopeTranscripts keeps the transcripts under scope (a directory).
func scopeTranscripts(transcripts []string, scope string) []string {
	var out []string
	prefix := scope
	if !strings.HasSuffix(prefix, string(filepath.Separator)) {
		prefix += string(filepath.Separator)
	}
	for _, p := range transcripts {
		if p == scope || strings.HasPrefix(p, prefix) {
			out = append(out, p)
		}
	}
	return out
}

// sessionMeta is the frontmatter subset the pickers surface.
type sessionMeta struct {
	description string
	createdCwd  string
	model       string
	turns       int
}

// parseMetaLines extracts the list fields from frontmatter lines. It stops at
// the closing `---`, so it is safe on a bare frontmatter block.
func parseMetaLines(lines []string) sessionMeta {
	var m sessionMeta
	if len(lines) == 0 || strings.TrimSpace(lines[0]) != "---" {
		return m
	}
	for _, line := range lines[1:] {
		line = strings.TrimSpace(line)
		if line == "---" {
			break
		}
		key, val, ok := strings.Cut(line, ":")
		if !ok {
			continue
		}
		val = strings.TrimSpace(val)
		switch key {
		case "description":
			m.description = val
		case "created_cwd":
			m.createdCwd = val
		case "model":
			m.model = val
		case "turns":
			m.turns, _ = strconv.Atoi(val)
		}
	}
	return m
}

// readFrontmatter streams only the frontmatter block of a transcript, so
// listing a multi-megabyte session never loads it whole.
func readFrontmatter(path string) sessionMeta {
	f, err := os.Open(path)
	if err != nil {
		return sessionMeta{}
	}
	defer func() { _ = f.Close() }()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 4096), 1<<20)
	var lines []string
	for sc.Scan() {
		lines = append(lines, sc.Text())
		if len(lines) >= 2 && strings.TrimSpace(sc.Text()) == "---" {
			break
		}
		if len(lines) >= 512 { // frontmatter is small; a pathological file ends the scan
			break
		}
	}
	return parseMetaLines(lines)
}

// parseDate accepts YYYY-MM-DD or RFC3339. The second bool reports whether the
// value was a bare date (no time part), so callers can widen it to a full day.
func parseDate(s string) (time.Time, bool, bool) {
	s = strings.TrimSpace(s)
	if s == "" {
		return time.Time{}, false, false
	}
	if t, err := time.Parse("2006-01-02", s); err == nil {
		return t, true, true
	}
	if t, err := time.Parse(time.RFC3339, s); err == nil {
		return t, true, false
	}
	return time.Time{}, false, false
}

func listSessions(a *sessionsArgs) (string, string, error) {
	root := utils.SessionsRoot()
	if root == "" {
		return "", "", fmt.Errorf("sessions root unavailable (sessions_dir was not sent with this turn)")
	}
	transcripts := sessionTranscripts(root)
	if a.Path != "" {
		transcripts = scopeTranscripts(transcripts, sessionsScope(root, a.Path))
	}

	var sinceT, untilT time.Time
	if a.Since != "" {
		t, ok, _ := parseDate(a.Since)
		if !ok {
			return "", "", fmt.Errorf("sessions: since %q is not a date (want YYYY-MM-DD or RFC3339)", a.Since)
		}
		sinceT = t
	}
	if a.Until != "" {
		t, ok, dateOnly := parseDate(a.Until)
		if !ok {
			return "", "", fmt.Errorf("sessions: until %q is not a date (want YYYY-MM-DD or RFC3339)", a.Until)
		}
		if dateOnly {
			t = t.Add(24*time.Hour - time.Nanosecond) // a bare date includes its whole day
		}
		untilT = t
	}
	filter := strings.ToLower(strings.TrimSpace(a.Filter))

	if len(transcripts) == 0 {
		return "(no sessions found)", "", nil
	}

	type item struct {
		path, desc, cwd, model string
		turns                  int
		mod                    time.Time
	}
	items := make([]item, 0, len(transcripts))
	for _, p := range transcripts {
		m := readFrontmatter(p)
		var mod time.Time
		if fi, err := os.Stat(p); err == nil {
			mod = fi.ModTime()
		}
		if !sinceT.IsZero() && mod.Before(sinceT) {
			continue
		}
		if !untilT.IsZero() && mod.After(untilT) {
			continue
		}
		if filter != "" {
			hay := strings.ToLower(m.description + "\n" + m.createdCwd + "\n" + m.model + "\n" + p)
			if !strings.Contains(hay, filter) {
				continue
			}
		}
		items = append(items, item{path: p, desc: m.description, cwd: m.createdCwd, model: m.model, turns: m.turns, mod: mod})
	}
	sort.Slice(items, func(i, j int) bool { return items[i].mod.After(items[j].mod) })

	var b strings.Builder
	fmt.Fprintf(&b, "%d session(s) under %s (most recent first)\n", len(items), root)
	if len(items) == 0 {
		return strings.TrimSpace(b.String()), "", nil
	}
	overflow := 0
	if len(items) > listMax {
		overflow = len(items) - listMax
		items = items[:listMax]
	}
	for _, it := range items {
		label := it.desc
		if label == "" {
			label = filepath.Base(filepath.Dir(it.path))
		}
		var meta []string
		if it.cwd != "" {
			meta = append(meta, "cwd="+it.cwd)
		}
		if it.model != "" {
			meta = append(meta, "model="+it.model)
		}
		if it.turns > 0 {
			meta = append(meta, fmt.Sprintf("%d turns", it.turns))
		}
		line := it.mod.Format("2006-01-02") + "  " + label
		if len(meta) > 0 {
			line += "  (" + strings.Join(meta, ", ") + ")"
		}
		b.WriteString(line + "\n  " + it.path + "\n")
	}
	if overflow > 0 {
		fmt.Fprintf(&b, "\n... %d more; narrow with filter, since/until, or path\n", overflow)
	}
	return strings.TrimSpace(b.String()), "", nil
}

// ─── search ────────────────────────────────────────────────────────────────

func searchSessions(pattern string) (string, string, error) {
	root := utils.SessionsRoot()
	if root == "" {
		return "", "", fmt.Errorf("sessions root unavailable (sessions_dir was not sent with this turn)")
	}
	if strings.TrimSpace(pattern) == "" {
		return "", "", fmt.Errorf("empty pattern")
	}
	// Restrict to transcripts: any .md, minus the notes sidecar and anything
	// under an assets/ working folder (which holds copies of other sessions).
	args := []string{
		"--line-number", "--no-heading", "--color", "never", "--max-count", "200",
		"--glob", "*.md", "--glob", "!**/assets/**", "--glob", "!notes.md",
		"--", pattern, root,
	}
	ctx, cancel := context.WithTimeout(wire.TurnContext(), searchTimeout)
	defer cancel()
	out, err := exec.CommandContext(ctx, "rg", args...).Output()
	if err != nil {
		if ctx.Err() != nil {
			return "", "", fmt.Errorf("rg timed out")
		}
		if ee, ok := err.(*exec.ExitError); ok && ee.ExitCode() == 1 {
			return "(no matches)", "", nil
		}
		return "", "", fmt.Errorf("rg: %w", err)
	}
	text := strings.TrimSuffix(string(out), "\n")
	if text == "" {
		return "(no matches)", "", nil
	}
	text, truncated := truncateHead(text)
	if truncated {
		text += "\n[truncated: narrow the pattern]"
	}
	return text, "", nil
}

// ─── read ──────────────────────────────────────────────────────────────────

// transcriptIn returns the transcript markdown inside a session directory
// (the .md that is not notes.md), or "" when the directory has none.
func transcriptIn(dir string) string {
	entries, err := os.ReadDir(dir)
	if err != nil {
		return ""
	}
	for _, e := range entries {
		if !e.IsDir() && e.Name() != "notes.md" && strings.HasSuffix(e.Name(), ".md") {
			return filepath.Join(dir, e.Name())
		}
	}
	return ""
}

// messageBody is one message's prose, with marker regions resolved.
type messageBody struct {
	role string
	line int
	body string
}

// readMessages extracts one entry per message heading: its role, 1-based
// heading line, and the prose body. Tool regions collapse to a single
// "[tool: name]" line; thinking/error/ui/usage region bodies are dropped, so
// the result is the conversation's readable text, not its raw markers.
func readMessages(doc *document.Document) []messageBody {
	lines := doc.Lines
	headingAt := make(map[int]string, len(doc.Headings))
	for _, h := range doc.Headings {
		headingAt[h.Line] = h.Role
	}

	// Normalize regions to 0-based inclusive [lo, hi] spans (regions are
	// already ordered by start line).
	type span struct {
		lo, hi     int
		kind, tool string
	}
	spans := make([]span, 0, len(doc.Regions))
	for _, r := range doc.Regions {
		lo := r.Start - 1
		hi := r.Finish
		if hi == 0 {
			hi = len(lines)
		}
		hi--
		if lo < 0 {
			lo = 0
		}
		if hi < lo {
			hi = lo
		}
		if hi >= len(lines) {
			hi = len(lines) - 1
		}
		tool := ""
		if r.Kind == "tool" {
			if h := document.DecodeToolHeader(lines, r); h != nil {
				tool = h.Name
			}
		}
		spans = append(spans, span{lo: lo, hi: hi, kind: r.Kind, tool: tool})
	}

	var out []messageBody
	var cur *messageBody
	flush := func() {
		if cur == nil {
			return
		}
		cur.body = strings.TrimSpace(cur.body)
		out = append(out, *cur)
		cur = nil
	}

	ri := 0
	for idx := 0; idx < len(lines); idx++ {
		lineNo := idx + 1
		if role, ok := headingAt[lineNo]; ok {
			flush()
			cur = &messageBody{role: role, line: lineNo}
			continue
		}
		if cur == nil {
			continue // text before the first heading is ignored
		}
		for ri < len(spans) && idx > spans[ri].hi {
			ri++
		}
		if ri < len(spans) && idx >= spans[ri].lo {
			if spans[ri].kind == "tool" && idx == spans[ri].lo {
				name := spans[ri].tool
				if name == "" {
					name = "tool"
				}
				cur.body += "\n[tool: " + name + "]"
			}
			continue
		}
		cur.body += "\n" + lines[idx]
	}
	flush()
	return out
}

func preview(s string) string {
	if i := strings.IndexByte(s, '\n'); i >= 0 {
		s = s[:i]
	}
	s = strings.TrimSpace(s)
	if len(s) > 80 {
		s = s[:80] + "…"
	}
	return s
}

// lineCount is the number of non-empty structural lines a message spans,
// reported so a skipped system message is still accounted for.
func lineCount(s string) int {
	if s == "" {
		return 0
	}
	return strings.Count(s, "\n") + 1
}

func readSession(a *sessionsArgs) (string, string, error) {
	path := strings.TrimSpace(a.Path)
	if path == "" {
		return "", "", fmt.Errorf("sessions read needs a path: a session transcript file or its directory")
	}
	path = utils.ExpandHome(path)
	if !filepath.IsAbs(path) {
		root := utils.SessionsRoot()
		if root == "" {
			return "", "", fmt.Errorf("sessions root unavailable (sessions_dir was not sent with this turn)")
		}
		path = filepath.Join(root, path)
	}
	if fi, err := os.Stat(path); err == nil && fi.IsDir() {
		path = transcriptIn(path)
	}
	if path == "" {
		return "", "", fmt.Errorf("no transcript found in that session")
	}
	data, err := os.ReadFile(path)
	if err != nil {
		return "", "", err
	}

	doc := document.Parse(string(data))
	meta := parseMetaLines(doc.Lines)
	msgs := readMessages(doc)

	var b strings.Builder
	label := meta.description
	if label == "" {
		label = filepath.Base(filepath.Dir(path))
	}
	b.WriteString("# " + label + "\n")
	b.WriteString("path: " + path + "\n")
	if meta.createdCwd != "" {
		b.WriteString("cwd: " + meta.createdCwd + "\n")
	}
	if meta.model != "" {
		b.WriteString("model: " + meta.model + "\n")
	}
	if meta.turns > 0 {
		fmt.Fprintf(&b, "turns: %d\n", meta.turns)
	}
	fmt.Fprintf(&b, "lines: %d  messages: %d\n\n", len(doc.Lines), len(msgs))

	start := a.Start
	if start < 1 {
		start = 1
	}
	count := a.Count
	if count <= 0 {
		count = len(msgs)
	}
	end := start + count - 1
	if end > len(msgs) {
		end = len(msgs)
	}

	b.WriteString("## outline\n")
	for i, m := range msgs {
		fmt.Fprintf(&b, "%d. @%s (line %d) %s\n", i+1, m.role, m.line, preview(m.body))
	}
	if start > len(msgs) {
		return strings.TrimSpace(b.String()), "", nil
	}
	b.WriteString("\n## prose")
	if start > 1 || end < len(msgs) {
		fmt.Fprintf(&b, " (messages %d..%d)", start, end)
	}
	b.WriteString("\n")
	for i := start - 1; i < end; i++ {
		m := msgs[i]
		if m.role == "system" && !a.IncludeSystem {
			fmt.Fprintf(&b, "\n### [%d] @system (line %d)\n[system message skipped: %d lines; set include_system to read it]\n", i+1, m.line, lineCount(m.body))
			continue
		}
		fmt.Fprintf(&b, "\n### [%d] @%s (line %d)\n%s\n", i+1, m.role, m.line, m.body)
	}

	text := strings.TrimSpace(b.String())
	text, truncated := truncateHead(text)
	if truncated {
		text += "\n[truncated: page with start/count, or read path offset=LINE limit=N for raw lines]"
	}
	return text, "", nil
}
