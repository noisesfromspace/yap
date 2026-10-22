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
