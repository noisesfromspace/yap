package utils

import (
	"fmt"
	"strings"
	"testing"
)

func TestUnifiedDiffModify(t *testing.T) {
	d := UnifiedDiff("f.txt", "one\ntwo\nthree\n", "one\nTWO\nthree\n")
	for _, want := range []string{"--- a/f.txt", "+++ b/f.txt", "@@", "-two", "+TWO"} {
		if !strings.Contains(d, want) {
			t.Fatalf("missing %q in:\n%s", want, d)
		}
	}
	// old and new lines must not cross over.
	if strings.Contains(d, "+two\n") || strings.Contains(d, "-TWO") {
		t.Fatalf("diff mixed up old/new:\n%s", d)
	}
}

func TestUnifiedDiffCreate(t *testing.T) {
	d := UnifiedDiff("new.txt", "", "hello\nworld\n")
	for _, l := range strings.Split(d, "\n") {
		if strings.HasPrefix(l, "-") && !strings.HasPrefix(l, "---") {
			t.Fatalf("create diff has a delete line: %q\n%s", l, d)
		}
	}
	if !strings.Contains(d, "+hello") || !strings.Contains(d, "+world") {
		t.Fatalf("create diff missing added lines:\n%s", d)
	}
}

func TestUnifiedDiffDelete(t *testing.T) {
	d := UnifiedDiff("gone.txt", "hello\nworld\n", "")
	for _, l := range strings.Split(d, "\n") {
		if strings.HasPrefix(l, "+") && !strings.HasPrefix(l, "+++") {
			t.Fatalf("delete diff has an add line: %q\n%s", l, d)
		}
	}
	if !strings.Contains(d, "-hello") || !strings.Contains(d, "-world") {
		t.Fatalf("delete diff missing removed lines:\n%s", d)
	}
}

func TestUnifiedDiffNoop(t *testing.T) {
	if d := UnifiedDiff("f.txt", "same", "same"); d != "" {
		t.Fatalf("identical content should diff to empty: %q", d)
	}
	// Total input over maxDiffBytes is refused (display-only, best-effort).
	big := strings.Repeat("x", 300*1024)
	if d := UnifiedDiff("f.txt", big, big+"!"); d != "" {
		t.Fatalf("oversized content should diff to empty (got %d bytes)", len(d))
	}
}

func TestUnifiedDiffMultiHunk(t *testing.T) {
	// Changes far apart must split into separate hunks, not one giant hunk.
	var old, newB strings.Builder
	for i := 1; i <= 30; i++ {
		fmt.Fprintf(&old, "line %d\n", i)
		line := fmt.Sprintf("line %d", i)
		if i == 1 || i == 30 {
			line = "CHANGED " + line
		}
		fmt.Fprintf(&newB, "%s\n", line)
	}
	d := UnifiedDiff("f.txt", old.String(), newB.String())
	if got := strings.Count(d, "@@"); got < 2 {
		t.Fatalf("expected 2 hunks, got %d:\n%s", got, d)
	}
}
