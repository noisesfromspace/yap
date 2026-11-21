package tools

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
	"unicode/utf8"
)

func TestTruncateHead(t *testing.T) {
	lines := make([]string, 2001)
	for i := range lines {
		lines[i] = "x"
	}
	out, truncated := truncateHead(strings.Join(lines, "\n"))
	if !truncated {
		t.Fatal("expected truncation")
	}
	if strings.Count(out, "\n") != 1999 {
		t.Fatalf("expected 2000 lines, got %d", strings.Count(out, "\n")+1)
	}

	// under the limit: unchanged, not truncated
	short, truncated := truncateHead("a\nb\nc")
	if truncated || short != "a\nb\nc" {
		t.Fatalf("short input changed: %q %v", short, truncated)
	}
}

func TestSearchAndGlob(t *testing.T) {
	if _, err := exec.LookPath("rg"); err != nil {
		t.Skip("rg not available")
	}
	dir := t.TempDir()
	needle := filepath.Join(dir, "a.go")
	if err := os.WriteFile(needle, []byte("func main() { fmt.Println(\"needle\") }\n"), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "search", `{"pattern":"needle","path":"`+dir+`"}`)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !strings.Contains(r, "a.go:1:") || !strings.Contains(r, "needle") {
		t.Fatalf("search result: %q", r)
	}

	g, _, err := run(t, "glob", `{"pattern":"**/*.go","path":"`+dir+`"}`)
	if err != nil {
		t.Fatalf("glob: %v", err)
	}
	if !strings.Contains(g, "a.go") {
		t.Fatalf("glob result: %q", g)
	}
}

func TestSearchFlags(t *testing.T) {
	if _, err := exec.LookPath("rg"); err != nil {
		t.Skip("rg not available")
	}
	dir := t.TempDir()
	content := "Foo one\nbar two\nfoo three\nbaz four\nfoo five\n"
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte(content), 0o644); err != nil {
		t.Fatal(err)
	}

	// case-insensitive matches all three "foo" lines
	r, _, err := run(t, "search", `{"pattern":"foo","path":"`+dir+`","case_insensitive":true}`)
	if err != nil || !strings.Contains(r, "Foo one") || !strings.Contains(r, "foo three") || !strings.Contains(r, "foo five") {
		t.Fatalf("case_insensitive: %q %v", r, err)
	}

	// invert returns only the non-matching lines
	r, _, err = run(t, "search", `{"pattern":"foo","path":"`+dir+`","invert":true}`)
	if err != nil || !strings.Contains(r, "bar two") || !strings.Contains(r, "baz four") || strings.Contains(r, "three") || strings.Contains(r, "five") {
		t.Fatalf("invert: %q %v", r, err)
	}

	// files_with_matches prints paths only
	r, _, err = run(t, "search", `{"pattern":"foo","path":"`+dir+`","files_with_matches":true}`)
	if err != nil || !strings.Contains(r, "a.txt") || strings.Contains(r, ":1:") {
		t.Fatalf("files_with_matches: %q %v", r, err)
	}

	// context shows the surrounding lines
	r, _, err = run(t, "search", `{"pattern":"bar two","path":"`+dir+`","context":1}`)
	if err != nil || !strings.Contains(r, "Foo one") || !strings.Contains(r, "foo three") {
		t.Fatalf("context: %q %v", r, err)
	}

	// count returns the per-file tally, not capped by max_count
	r, _, err = run(t, "search", `{"pattern":"foo","path":"`+dir+`","count":true,"case_insensitive":true}`)
	if err != nil || !strings.Contains(r, "a.txt:3") {
		t.Fatalf("count: %q %v", r, err)
	}
}

func TestSearchNoMatches(t *testing.T) {
	if _, err := exec.LookPath("rg"); err != nil {
		t.Skip("rg not available")
	}
	dir := t.TempDir()
	r, _, err := run(t, "search", `{"pattern":"definitely-not-here-xyz","path":"`+dir+`"}`)
	if err != nil || r != "(no matches)" {
		t.Fatalf("no matches: %q %v", r, err)
	}
}

func TestVimToPCRE(t *testing.T) {
	cases := []struct{ in, want string }{
		{"plain pattern", "plain pattern"},
		{`foo\(bar\|baz\)`, `foo(bar|baz)`},
		{`\<word\>`, `\bword\b`},
		{`a\+b`, `a+b`},
		{`\%(ab\)`, `(?:ab)`},
		{`\d{2}`, `\d{2}`}, // no Vim escape: untouched
	}
	for _, c := range cases {
		if got := vimToPCRE(c.in); got != c.want {
			t.Fatalf("vimToPCRE(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestSearchVimEscapesTranslated(t *testing.T) {
	if _, err := exec.LookPath("rg"); err != nil {
		t.Skip("rg not available")
	}
	dir := t.TempDir()
	if err := os.WriteFile(filepath.Join(dir, "a.txt"), []byte("foo bar\nfoo baz\nfoo qux\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	// Vim alternation `\|` must become PCRE `|` before ripgrep sees it.
	r, _, err := run(t, "search", `{"pattern":"bar\\|baz","path":"`+dir+`"}`)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !strings.Contains(r, "foo bar") || !strings.Contains(r, "foo baz") || strings.Contains(r, "foo qux") {
		t.Fatalf("vim alternation not translated: %q", r)
	}
}

// `path` can point anywhere, so searching a secret directory must hit the
// same secret-path rule read does (approvable, not silently searched).
func TestSearchSecretPathRule(t *testing.T) {
	if reason := Match("search", json.RawMessage(`{"pattern":"x","path":"~/.ssh"}`)); reason != "searches a secret path" {
		t.Fatalf("~/.ssh: reason=%q", reason)
	}
	if reason := Match("search", json.RawMessage(`{"pattern":"x","path":"/run/agenix.d"}`)); reason != "searches a secret path" {
		t.Fatalf("agenix: reason=%q", reason)
	}
	if reason := Match("search", json.RawMessage(`{"pattern":"x","path":"/tmp"}`)); reason != "" {
		t.Fatalf("non-secret path: reason=%q", reason)
	}
}

func TestTruncateBytesKeepsRuneBoundaryAndNotice(t *testing.T) {
	got := truncateBytes("日abc", 2, "\n[cut]")
	if got != "\n[cut]" || !utf8.ValidString(got) {
		t.Fatalf("truncation split a rune: %q", got)
	}
	if got := truncateBytes("日abc", 6, "\n[cut]"); got != "日abc" {
		t.Fatalf("short input changed: %q", got)
	}
}

// The byte cap must not split a multi-byte character: half a rune in a tool
// result makes Neovim read the transcript back as latin1 and re-encode it.
func TestCapBytesKeepsRuneBoundary(t *testing.T) {
	s := strings.Repeat("日", 10) // 30 bytes, 3 bytes per rune
	got := capBytes(s, 5)
	if len(got) > 5 {
		t.Fatalf("capBytes returned %d bytes, want <= 5", len(got))
	}
	if !utf8.ValidString(got) || got != "日" {
		t.Fatalf("capBytes split a rune: %q", got)
	}
	if capBytes("abc", 5) != "abc" {
		t.Fatal("capBytes should pass short input through")
	}
}
