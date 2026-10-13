package render

import (
	"bufio"
	"bytes"
	"testing"
)

func escapeProse(t *testing.T, in string) string {
	t.Helper()
	var buf bytes.Buffer
	out := bufio.NewWriter(&buf)
	p := NewProseEscaper(out)
	p.WriteString(in)
	p.Flush()
	return buf.String()
}

func TestProseEscaperNeutralizesStructuralLines(t *testing.T) {
	in := "The marker is:\n<!-- yap:tool {} -->\nand it ends with:\n<!-- /yap:tool -->\nplus a heading:\n# @user\nand a raw tag:\n<style>x</style>\n"
	want := "The marker is:\n\\<!-- yap:tool {} -->\nand it ends with:\n\\<!-- /yap:tool -->\nplus a heading:\n\\# @user\nand a raw tag:\n\\<style>x</style>\n"
	if got := escapeProse(t, in); got != want {
		t.Errorf("escaped prose:\n got %q\nwant %q", got, want)
	}
}

func TestProseEscaperLeavesFencedContentAlone(t *testing.T) {
	in := "Here is the format:\n```markdown\n<!-- yap:tool {} -->\n# @user\n```\nBut outside a fence it must be escaped:\n<!-- yap:tool {} -->\n"
	want := "Here is the format:\n```markdown\n<!-- yap:tool {} -->\n# @user\n```\nBut outside a fence it must be escaped:\n\\<!-- yap:tool {} -->\n"
	if got := escapeProse(t, in); got != want {
		t.Errorf("fence-aware prose:\n got %q\nwant %q", got, want)
	}
}

func TestProseEscaperTildeFence(t *testing.T) {
	in := "~~~\n# @user\n~~~\n# @user\n"
	want := "~~~\n# @user\n~~~\n\\# @user\n"
	if got := escapeProse(t, in); got != want {
		t.Errorf("tilde fence:\n got %q\nwant %q", got, want)
	}
}

func TestProseEscaperBacktickInInfoStringIsNotAFence(t *testing.T) {
	// A backtick in the info string is not a valid CommonMark fence opener,
	// so the escaper must not latch inFence on it and stop escaping.
	in := "```go`\n# @user\n"
	want := "```go`\n\\# @user\n"
	if got := escapeProse(t, in); got != want {
		t.Errorf("backtick in info string:\n got %q\nwant %q", got, want)
	}
}

func TestEscapeProseText(t *testing.T) {
	in := "line one\n# @assistant\n<!-- yap:tool {} -->\n# @system, with prose"
	want := "line one\n\\# @assistant\n\\<!-- yap:tool {} -->\n# @system, with prose"
	if got := EscapeProseText(in); got != want {
		t.Errorf("EscapeProseText:\n got %q\nwant %q", got, want)
	}
}

func TestProseEscaperPreservesTrailingNewlineCount(t *testing.T) {
	if got := escapeProse(t, "a\nb"); got != "a\nb" {
		t.Errorf("no trailing newline: got %q", got)
	}
	if got := escapeProse(t, "a\nb\n"); got != "a\nb\n" {
		t.Errorf("one trailing newline: got %q", got)
	}
}

func TestProseEscaperSplitsMarkerAcrossChunks(t *testing.T) {
	var buf bytes.Buffer
	out := bufio.NewWriter(&buf)
	p := NewProseEscaper(out)
	p.WriteString("<!-- yap")
	p.WriteString(":tool {} -->\n")
	p.Flush()
	if got := buf.String(); got != "\\<!-- yap:tool {} -->\n" {
		t.Errorf("marker split across chunks leaked unescaped: %q", got)
	}
}

func TestEscapeCommentRoleHeading(t *testing.T) {
	if got := escapeComment("# @user"); got != "\\# @user" {
		t.Errorf("role heading: got %q", got)
	}
	if got := escapeComment("# @user, with prose"); got != "# @user, with prose" {
		t.Errorf("non-heading left alone: got %q", got)
	}
	if got := escapeComment("a --> b"); got != "a -- > b" {
		t.Errorf("--> neutralized: got %q", got)
	}
	if got := escapeComment("## Title"); got != "## Title" {
		t.Errorf("normal heading left alone: got %q", got)
	}
}
