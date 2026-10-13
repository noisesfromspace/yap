package utils

import (
	"encoding/json"
	"strings"
	"testing"
)

func TestSlimArgs(t *testing.T) {
	// write: content becomes a line count, path survives
	args, ok := SlimArgs("write", `{"path":"/tmp/x.md","content":"line one\nline two\nline three"}`)
	if !ok {
		t.Fatal("write not slimmed")
	}
	b, _ := json.Marshal(args)
	s := string(b)
	if !strings.Contains(s, `"content":"[3 lines]"`) || !strings.Contains(s, `"path":"/tmp/x.md"`) {
		t.Fatalf("unexpected slimmed write args: %s", s)
	}
	if strings.Contains(s, "line one") {
		t.Fatalf("slimmed header leaks content: %s", s)
	}

	// edit: edits become a summary with +/- line counts
	args, ok = SlimArgs("edit", `{"path":"/tmp/y.go","edits":[{"oldText":"a\nb","newText":"c"},{"oldText":"d","newText":"e\nf\ng"}]}`)
	if !ok {
		t.Fatal("edit not slimmed")
	}
	b, _ = json.Marshal(args)
	if s := string(b); !strings.Contains(s, `"edits":"[2 edits, +4/-3 lines]"`) {
		t.Fatalf("unexpected slimmed edit args: %s", s)
	}

	// other tools keep their arguments verbatim
	if _, ok = SlimArgs("bash", `{"command":"ls"}`); ok {
		t.Fatal("bash should not be slimmed")
	}

	// malformed JSON falls back to the verbatim header
	if _, ok = SlimArgs("write", `{not json`); ok {
		t.Fatal("malformed write args should not be slimmed")
	}

	// a trailing newline terminates the last line instead of starting an
	// empty one: "a\nb\nc\n" is a 3-line file, not 4
	args, ok = SlimArgs("write", `{"path":"/tmp/x","content":"a\nb\nc\n"}`)
	if !ok {
		t.Fatal("write with trailing newline not slimmed")
	}
	b, _ = json.Marshal(args)
	if s := string(b); !strings.Contains(s, `"content":"[3 lines]"`) {
		t.Fatalf("trailing newline miscounted: %s", s)
	}

	// arguments that parse but do not carry the summarized fields keep the
	// verbatim header instead of a confidently wrong "[0 lines]"
	if _, ok = SlimArgs("write", `{"path":"/tmp/x"}`); ok {
		t.Fatal("write without content should not be slimmed")
	}
	if _, ok = SlimArgs("edit", `{"path":"/tmp/x","edits":[{"oldText":"a"}]}`); ok {
		t.Fatal("edit without newText should not be slimmed")
	}
	if _, ok = SlimArgs("edit", `{"path":"/tmp/x"}`); ok {
		t.Fatal("edit without edits should not be slimmed")
	}
}
