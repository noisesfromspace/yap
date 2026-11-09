package lsp

import (
	"encoding/json"
	"os"
	"path/filepath"
	"sort"
	"testing"
)

// TestFrontmatterKeysConformance locks the Go frontmatter field inventory to
// the shared fixture, so it cannot drift from the Lua writer
// (lua/harness/model/frontmatter.lua) without both conformance tests failing.
func TestFrontmatterKeysConformance(t *testing.T) {
	path := filepath.Join("..", "..", "tests", "frontmatter_keys.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read conformance fixture: %v", err)
	}
	var want []string
	if err := json.Unmarshal(data, &want); err != nil {
		t.Fatalf("parse conformance fixture: %v", err)
	}

	got := make([]string, 0, len(fields))
	for _, f := range fields {
		got = append(got, f.name)
	}
	sort.Strings(got)
	sort.Strings(want)

	if len(got) != len(want) {
		t.Fatalf("field count: got %d, want %d", len(got), len(want))
	}
	for i := range want {
		if got[i] != want[i] {
			t.Errorf("field set mismatch at %d: got %q, want %q", i, got[i], want[i])
		}
	}
}
