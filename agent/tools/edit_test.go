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

// rangeEdit marshals a single from/to edit into tool JSON, avoiding the
// backslash escaping that inline JSON would need for multi-line newText.
func rangeEdit(t *testing.T, p string, edit map[string]string) string {
	t.Helper()
	b, err := json.Marshal(map[string]any{"path": p, "edits": []map[string]string{edit}})
	if err != nil {
		t.Fatal(err)
	}
	return string(b)
}

func TestEditRangeDelete(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("a\nfunc old() {\n  x\n}\nb\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	r, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "func old() {", "to": "}"}))
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	if !strings.Contains(r, "Successfully replaced 1 edit(s)") {
		t.Fatalf("result: %q", r)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "a\nb\n" {
		t.Fatalf("content: %q", data)
	}
}

func TestEditRangeReplace(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("a\nfunc old() {\n  x\n}\nb\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "func old() {", "to": "}", "newText": "func new() {\n  y\n}"}))
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "a\nfunc new() {\n  y\n}\nb\n" {
		t.Fatalf("content: %q", data)
	}
}

func TestEditRangeToEOF(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("a\nfunc old() {\n  x\n}\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "func old() {", "to": "<eof>"}))
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "a\n" {
		t.Fatalf("content: %q", data)
	}
}

func TestEditRangeNestedBraces(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if err := os.WriteFile(p, []byte("func outer() {\n  if x {\n    y\n  }\n  z\n}\nnext\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	_, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "func outer() {", "to": "}"}))
	if err != nil {
		t.Fatalf("edit: %v", err)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "next\n" {
		t.Fatalf("content: %q", data)
	}
}

func TestEditRangeErrors(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	// from not unique
	if err := os.WriteFile(p, []byte("x\nx\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "x", "to": "<eof>"})); err == nil || !strings.Contains(err.Error(), "matches 2 lines") {
		t.Fatalf("non-unique from: %v", err)
	}
	// to not found after from
	if err := os.WriteFile(p, []byte("}\nfunc f() {\n"), 0o644); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "edit", rangeEdit(t, p, map[string]string{"from": "func f() {", "to": "}"})); err == nil || !strings.Contains(err.Error(), "not found after from") {
		t.Fatalf("to not found: %v", err)
	}
	// both forms
	if _, _, err := run(t, "edit", `{"path":"`+p+`","edits":[{"oldText":"a","from":"b"}]}`); err == nil || !strings.Contains(err.Error(), "both oldText and from") {
		t.Fatalf("both forms: %v", err)
	}
}
