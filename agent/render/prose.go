package render

import (
	"bufio"
	"bytes"
	"regexp"
	"strings"
)

// roleHeadingRe matches a bare yap role heading (`# @user`, `# @assistant`,
// `# @system`) — the message-boundary syntax the harness emits and the Lua
// parser treats as structure. Any ASCII word after `# @`, then only
// whitespace.
var roleHeadingRe = regexp.MustCompile(`^# @[A-Za-z]+\s*$`)

// escapeProseLine neutralizes structural tokens in a streamed prose line
// that is NOT inside a fenced code block. Inside a fence the caller does not
// call this (those lines are literal content — the model may be showing
// yap's own syntax as an example). A visible backslash-escape is valid
// CommonMark for ASCII punctuation: renderers show the literal text while
// the line-start-anchored Lua parsers (and treesitter for tags) no longer
// match.
func escapeProseLine(line string) string {
	if strings.HasPrefix(line, "<!-- yap:") || strings.HasPrefix(line, "<!-- /yap:") {
		return "\\" + line
	}
	if roleHeadingRe.MatchString(line) {
		return "\\" + line
	}
	return rawTextTagRe.ReplaceAllString(line, "\\<$1$2")
}

// ProseEscaper buffers streamed assistant prose to line granularity and
// neutralizes structural tokens (yap markers, role headings, raw
// style/script tags) on complete lines outside a fenced code block. Inside a
// fence those lines are literal content and pass through unchanged, so the
// model can show yap's own syntax as examples. Fence tracking follows
// CommonMark: an opener is up to 3 spaces then a run of >=3 backticks or
// tildes; a closer is a run of the same character at least as long followed
// only by whitespace.
type ProseEscaper struct {
	w         *bufio.Writer
	buf       []byte
	inFence   bool
	fenceChar byte
	fenceLen  int
}

// NewProseEscaper returns a ProseEscaper writing to w.
func NewProseEscaper(w *bufio.Writer) *ProseEscaper {
	return &ProseEscaper{w: w}
}

// WriteString buffers s and writes complete lines through the escaper,
// flushing the underlying writer so complete lines appear immediately.
// A partial line is held until its newline arrives: a marker split across
// chunks must not leak out unescaped.
func (p *ProseEscaper) WriteString(s string) {
	p.buf = append(p.buf, s...)
	for {
		i := bytes.IndexByte(p.buf, '\n')
		if i < 0 {
			break
		}
		p.writeLine(string(p.buf[:i]), true)
		p.buf = p.buf[i+1:]
	}
	p.w.Flush()
}

// Flush writes any partial line remaining in the buffer, without adding a
// trailing newline (the text did not have one), so the buffer's trailing
// newline count stays exactly what the model produced.
func (p *ProseEscaper) Flush() {
	if len(p.buf) > 0 {
		p.writeLine(string(p.buf), false)
		p.buf = nil
	}
	p.w.Flush()
}

// writeLine classifies one complete line and writes it, with a trailing
// newline when nl is set (i.e. the line came from a real newline in the
// stream, not from the final partial Flush).
func (p *ProseEscaper) writeLine(line string, nl bool) {
	suffix := ""
	if nl {
		suffix = "\n"
	}
	if p.inFence {
		if c, k, tail, ok := fenceLine(line); ok && c == p.fenceChar && k >= p.fenceLen && strings.TrimSpace(tail) == "" {
			p.inFence = false
		}
		p.w.WriteString(line + suffix)
		return
	}
	if c, k, _, ok := fenceLine(line); ok {
		p.inFence = true
		p.fenceChar = c
		p.fenceLen = k
		p.w.WriteString(line + suffix)
		return
	}
	p.w.WriteString(escapeProseLine(line) + suffix)
}
