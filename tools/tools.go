// Package tools holds pitel's built-in tools: one file per tool, each
// self-registering in init(). Adding or changing a tool = editing a file
// here and recompiling (CGO_ENABLED=0).
//
// Read-only tools only, until an explicit decision on file-mutating tools
// (doc: R15).
package tools

import (
	"encoding/json"
	"sort"
)

// Tool is a single callable tool. result is sent back to the model; ui is
// an optional display-only payload for the buffer (pitel:ui, R12).
type Tool struct {
	Name        string
	Description string
	Schema      string // parameters JSON schema, sent to the provider
	Run         func(args json.RawMessage) (result, ui string, err error)
}

var registry = map[string]*Tool{}

// Register adds a tool; called from each tool file's init().
func Register(t *Tool) { registry[t.Name] = t }

// Get returns a tool by name.
func Get(name string) (*Tool, bool) {
	t, ok := registry[name]
	return t, ok
}

// All returns all registered tools, sorted by name (stable requests).
func All() []*Tool {
	names := make([]string, 0, len(registry))
	for n := range registry {
		names = append(names, n)
	}
	sort.Strings(names)
	out := make([]*Tool, 0, len(names))
	for _, n := range names {
		out = append(out, registry[n])
	}
	return out
}
