package tools

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"
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
