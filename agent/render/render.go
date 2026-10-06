// Package render turns the agent's tool activity into markdown for the
// chat buffer: the yap:tool / yap:usage markers, HTML-comment escaping for
// thinking text and tool headers/results, and the fenced-code-block logic.
// These concerns used to be split between package main and package utils;
// keeping them in one package gives the Lua parser and the markdown
// renderers a single Go counterpart to stay in sync with.
package render

import (
	"bufio"
	"bytes"
	"encoding/json"
	"fmt"
	"regexp"
	"strings"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/utils"
)

// toolHeaderMaxSingle is the longest header kept on one line; longer
// calls (write/edit content) are emitted as pretty-printed multi-line
// JSON inside the marker, which the Lua side folds closed by default.
const toolHeaderMaxSingle = 120

// escapeComment neutralizes every `-->` in text that lives inside an
// HTML comment region (thinking, ui): HTML comments are not line-based,
// so even an inline `-->` (e.g. in backticked prose) closes the comment
// early for markdown renderers. A space keeps the text readable. (A
// backslash-escape can't work here: `\-->` still CONTAINS the `-->`
// sequence a character-based comment scanner looks for.)
func escapeComment(s string) string {
	return strings.ReplaceAll(s, "-->", "-- >")
}

// CommentEscaper buffers streamed text to line granularity so dangerous
// sequences can be neutralized before they reach the buffer. Used for
// thinking text: ANY `-->` closes the HTML comment for renderers, even
// inline — so every one is neutralized. Chunks split mid-line, so
// per-chunk replacement doesn't work.
type CommentEscaper struct {
	w      *bufio.Writer
	buf    []byte
	esc    func(string) string
	lastNL bool // last byte written to w was '\n'
}

// NewCommentEscaper returns a CommentEscaper that neutralizes `-->` in
// each line before writing it to w.
func NewCommentEscaper(w *bufio.Writer) *CommentEscaper {
	return &CommentEscaper{w: w, esc: escapeComment}
}

// WriteString buffers s and writes whole lines through the escaper.
func (l *CommentEscaper) WriteString(s string) {
	l.buf = append(l.buf, s...)
	flushed := false
	for {
		i := bytes.IndexByte(l.buf, '\n')
		if i < 0 {
			break
		}
		l.w.WriteString(l.esc(string(l.buf[:i])) + "\n")
		l.buf = l.buf[i+1:]
		flushed = true
	}
	if flushed {
		l.lastNL = true
		l.w.Flush()
	}
}

// Flush writes any partial line remaining in the buffer.
func (l *CommentEscaper) Flush() {
	if len(l.buf) > 0 {
		l.w.WriteString(l.esc(string(l.buf)))
		l.buf = nil
		l.lastNL = false
	}
	l.w.Flush()
}

// LastNL reports whether the last byte written was a newline.
func (l *CommentEscaper) LastNL() bool {
	return l.lastNL
}

// MarshalCommentJSON renders v as JSON safe to embed inside an HTML
// comment (`<!-- yap:tool … -->`, `<!-- yap:usage … -->`). json.Marshal's
// default HTML-escaping turns `&`, `<` and `>` into `\u0026` etc.; those
// sequences then sit in the buffer as literal backslash text and read like
// a mangled command. Only two constructs are load-bearing, and both are
// kept as JSON escapes so the Lua side still decodes the original text:
//   - `-->` would close the HTML comment early for markdown renderers,
//     so it becomes `--\u003e`;
//   - a raw `<style`/`<script` open tag poisons treesitter's combined
//     html/css/js injections (see escapeMarkerPrefixes), so its `<`
//     becomes `\u003c`.
//
// Everything else stays readable. indent indents each level.
func MarshalCommentJSON(v any, indent string) []byte {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	enc.SetIndent("", indent)
	_ = enc.Encode(v) // payloads here are built by yap and cannot fail
	b := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
	b = bytes.ReplaceAll(b, []byte("-->"), []byte(`--\u003e`))
	b = rawTextTagRe.ReplaceAll(b, []byte(`\u003c$1$2`))
	return b
}

// rawTextTagRe matches `<style`/`<script` open tags (see
// escapeMarkerPrefixes).
var rawTextTagRe = regexp.MustCompile(`(?i)<(style|script)([\s>/])`)

// escapeMarkerPrefixes neutralizes dangerous constructs in tool results
// (raw markdown in the buffer) with a VISIBLE backslash-escape, valid
// CommonMark for ASCII punctuation: renderers show the literal text,
// treesitter sees an escape instead of a tag, and the line-start-anchored
// Lua parser never matches. No invisible bytes (a ZWSP breaks
// markdown_inline's html_tag grammar and renders as a literal <200b>;
// a soft hyphen hides corruption from the user while still reaching
// registers and the model).
//
// Two cases:
//   - lines starting with a yap marker opener — they would end the
//     tool region early during parsing;
//   - `<style`/`<script` open tags — in an extracted-Markdown result
//     (fetch converts pages to Markdown, which may embed raw HTML)
//     treesitter's combined HTML injection hands their
//     content to the css/javascript parsers, whose raw-text injection
//     ranges then bleed to the end of the buffer.
func escapeMarkerPrefixes(s string) string {
	s = rawTextTagRe.ReplaceAllString(s, "\\<$1$2")
	lines := strings.Split(s, "\n")
	for i, l := range lines {
		if strings.HasPrefix(l, "<!-- yap:") || strings.HasPrefix(l, "<!-- /yap:") {
			lines[i] = "\\" + l
		}
	}
	return strings.Join(lines, "\n")
}

// EmitToolHeader writes the yap:tool opener (full call as JSON)
// immediately when the model commits to the call — the arguments are
// visible in the buffer while the tool runs, and the gap to the result
// honestly represents execution time. Flushed so the header lands
// before a long-running tool's result. Blocks carry no leading
// newlines; the caller pads (one blank line between blocks, R7).
func EmitToolHeader(out *bufio.Writer, call llm.ToolCall) {
	// write/edit carry their full content in the arguments; the header
	// keeps only the shape — the yap:ui diff shows the change and the
	// audit log has the full arguments (R12).
	argsJSON := utils.Scrub(string(call.Input))
	args, ok := utils.SlimArgs(call.Name, argsJSON)
	if !ok {
		if err := json.Unmarshal([]byte(argsJSON), &args); err != nil {
			args = argsJSON // malformed/truncated JSON: keep raw
		}
	}
	// Struct, not map: stable key order (id, name, arguments).
	header := MarshalCommentJSON(struct {
		ID        string `json:"id"`
		Name      string `json:"name"`
		Arguments any    `json:"arguments"`
	}{call.ID, call.Name, args}, "")
	if len(header) <= toolHeaderMaxSingle {
		fmt.Fprintf(out, "<!-- yap:tool %s -->\n", header)
	} else {
		pretty := MarshalCommentJSON(json.RawMessage(header), "  ")
		fmt.Fprintf(out, "<!-- yap:tool\n%s\n-->\n", pretty)
	}
	out.Flush()
}

// EmitToolResult finishes an open yap:tool region: the result text
// (what the model received), an optional display-only ui section, and
// the region closer.
func EmitToolResult(out *bufio.Writer, result, ui string) {
	result = escapeMarkerPrefixes(result)
	out.WriteString(result + "\n")
	// Results are raw markdown in the buffer. A fence left open (truncated
	// read/bash output, or a file that genuinely contains a lone ``` line)
	// would swallow the rest of the buffer as a code block in every
	// CommonMark renderer, treesitter included. Close it before the ui
	// block so that still parses.
	if fence := unclosedFence(strings.Split(result, "\n")); fence != "" {
		out.WriteString(fence + "\n")
	}
	if ui != "" {
		ui = utils.Scrub(ui)
		// The ui diff used to live INSIDE a `<!-- yap:ui … -->` comment,
		// where treesitter never parses a fence — a comment is one leaf
		// html_block node, so a ```diff inside it got no highlighting.
		// Paired one-line markers leave the fence at block level, so the
		// markdown grammar parses it and injects the diff parser.
		fence := backtickFence(ui)
		fmt.Fprintf(out, "<!-- yap:ui -->\n%sdiff\n%s\n%s\n<!-- /yap:ui -->\n", fence, ui, fence)
	}
	// Regions self-terminate with exactly one blank line (R7).
	out.WriteString("<!-- /yap:tool -->\n\n")
	out.Flush()
}
