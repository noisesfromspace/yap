package tools

import (
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
