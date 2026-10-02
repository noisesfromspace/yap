package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

// TestFenceConformance asserts that fenceLine classifies fence openers
// identically to Lua's fold.fence_run. The cases live in a shared JSON
// fixture so the two grammars cannot drift apart unnoticed; a change to
// one must pass the same table as the other.
func TestFenceConformance(t *testing.T) {
	path := filepath.Join("..", "tests", "fence_cases.json")
	data, err := os.ReadFile(path)
	if err != nil {
		t.Fatalf("read conformance fixture: %v", err)
	}
	type kase struct {
		Line string `json:"line"`
		Char string `json:"char,omitempty"`
		Run  int    `json:"run,omitempty"`
		Tail string `json:"tail,omitempty"`
		Null bool   `json:"null,omitempty"`
	}
	var cases []kase
	if err := json.Unmarshal(data, &cases); err != nil {
		t.Fatalf("parse conformance fixture: %v", err)
	}
	if len(cases) == 0 {
		t.Fatal("conformance fixture is empty")
	}
	for _, c := range cases {
		char, run, tail, ok := fenceLine(c.Line)
		if c.Null {
			if ok {
				t.Errorf("fenceLine(%q) = (%q, %d, %q), want no fence", c.Line, char, run, tail)
			}
			continue
		}
		if !ok || string(char) != c.Char || run != c.Run || tail != c.Tail {
			t.Errorf("fenceLine(%q) = (%q, %d, %q, %v), want (%q, %d, %q)",
				c.Line, char, run, tail, ok, c.Char, c.Run, c.Tail)
		}
	}
}
