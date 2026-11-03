package tools

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestEditMultipleDisjoint(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("alpha beta gamma"), 0o644); err != nil {
		t.Fatal(err)
	}

	r, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"alpha","newText":"one"},{"oldText":"gamma","newText":"three"}]}`)
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	if !strings.Contains(r, "Successfully replaced 2 edit(s)") {
		t.Fatalf("result: %q", r)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "one beta three" {
		t.Fatalf("content: %q", data)
	}
}

func TestEditOverlap(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("abcdef"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"abc","newText":"123"},{"oldText":"cde","newText":"456"}]}`)
	if err == nil || !strings.Contains(err.Error(), "overlaps another edit") {
		t.Fatalf("overlap: %v", err)
	}
}

func TestEditNonUnique(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("x x"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"x","newText":"y"}]}`); err == nil || !strings.Contains(err.Error(), "matches 2 times") {
		t.Fatalf("non-unique: %v", err)
	}
}

func TestEditNotFound(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"zzz","newText":"y"}]}`); err == nil || !strings.Contains(err.Error(), "not found") {
		t.Fatalf("not found: %v", err)
	}
}

func TestEditValidation(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("abc"), 0o644); err != nil {
		t.Fatal(err)
	}
	// empty oldText and a missing file are both tool errors
	if _, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"","newText":"y"}]}`); err == nil || !strings.Contains(err.Error(), "empty") {
		t.Fatalf("empty oldText: %v", err)
	}
	if _, _, err := run(t, "edit", `{"path":"`+filepath.Join(t.TempDir(), "nope.txt")+`","edits":[{"oldText":"a","newText":"b"}]}`); err == nil || !strings.Contains(err.Error(), "does not exist") {
		t.Fatalf("missing file: %v", err)
	}
}

func TestEditDiagnosticsAndAtomicBatch(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	original := "alpha\n  unique\nbeta\n  unique\n"
	if err := os.WriteFile(p, []byte(original), 0o644); err != nil {
		t.Fatal(err)
	}
	cases := []struct{ name, old, want string }{
		{"missing", "absent", "not found"},
		{"drift", "beta\ngamma", "first line found at line(s) 3 but full block differs"},
		{"whitespace", "unique \nbeta", "different surrounding whitespace at line(s) 2, 4"},
		{"nonunique", "  unique", "at lines 2, 4"},
		{"overlap", "alpha", "overlaps another edit (edits[0], lines 1-2)"},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			first := "alpha\n  unique"
			args, err := json.Marshal(map[string]any{"path": p, "edits": []map[string]string{
				{"oldText": first, "newText": "changed"}, {"oldText": tc.old, "newText": "changed"},
			}})
			if err != nil {
				t.Fatal(err)
			}
			_, _, err = run(t, "edit", string(args))
			if err == nil || !strings.Contains(err.Error(), tc.want) || !strings.Contains(err.Error(), "no edits applied") {
				t.Fatalf("wanted %q and atomicity in error, got %v", tc.want, err)
			}
			data, _ := os.ReadFile(p)
			if string(data) != original {
				t.Fatalf("failed batch modified file: %q", data)
			}
		})
	}
}

func TestEditCRLFHint(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("one\r\ntwo\r\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"one\ntwo","newText":"x"}]}`)
	if err == nil || !strings.Contains(err.Error(), "line endings differ") {
		t.Fatalf("CRLF hint: %v", err)
	}
}

func TestEditRequiresBothTextFields(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("x"), 0o644); err != nil {
		t.Fatal(err)
	}
	for _, edit := range []string{`{"newText":"y"}`, `{"oldText":"x"}`} {
		_, _, err := run(t, "edit", `{"path":"`+p+`","edits":[`+edit+`]}`)
		if err == nil || !strings.Contains(err.Error(), "missing property") {
			t.Fatalf("expected missing field: %v", err)
		}
	}
}

func TestEditRejectsRangeFields(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("x\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"from":"x","to":"<eof>","newText":"y"}]}`)
	if err == nil || !strings.Contains(err.Error(), "additional properties") {
		t.Fatalf("range fields should fail schema validation: %v", err)
	}
}
