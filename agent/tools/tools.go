// Package tools holds pitel's built-in tools: one file per tool, each
// self-registering in init(). Adding or changing a tool = editing a file
// here and recompiling (CGO_ENABLED=0).
//
// Tools define an Args struct; the JSON schema sent to the provider is
// generated from it by reflection (invopop/jsonschema), and incoming
// model arguments are validated against the compiled schema
// (santhosh-tekuri/jsonschema) before Run is called — hand-written
// schemas and raw unmarshal errors are both gone.
package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"sync"
	"syscall"

	"github.com/invopop/jsonschema"
	schema "github.com/santhosh-tekuri/jsonschema/v6"
)

// StreamFunc receives display-only output chunks while a tool runs
// (bash command output). Chunks are line-aligned except possibly the
// last (a line still being written when the process exits). The agent
// loop renders them into the buffer's pitel:stream region; they never
// reach the model, so volume is not a context concern.
type StreamFunc func(chunk string)

// Tool is a single callable tool. result is sent back to the model; ui is
// an optional display-only payload for the buffer (pitel:ui, R12).
type Tool struct {
	Name        string
	Description string
	Schema      json.RawMessage // generated from the tool's Args struct
	compiled    *schema.Schema
	run         func(args json.RawMessage) (result, ui string, err error)
	runStream   func(args json.RawMessage, emit StreamFunc) (result, ui string, err error)
}

var registry = map[string]*Tool{}

// Run executes the tool's validated run function.
func (t *Tool) Run(args json.RawMessage) (result, ui string, err error) {
	return t.run(args)
}

// RunStream executes the tool with a chunk callback when the tool
// streams; otherwise it is Run.
func (t *Tool) RunStream(args json.RawMessage, emit StreamFunc) (result, ui string, err error) {
	if t.runStream == nil {
		return t.run(args)
	}
	return t.runStream(args, emit)
}

// Register adds a tool; called from each tool file's init(). T is the
// tool's argument struct: json tags name the parameters (omitempty =
// optional), jsonschema tags carry descriptions.
func Register[T any](name, description string, run func(args *T) (result, ui string, err error)) {
	RegisterStream(name, description, func(a *T, _ StreamFunc) (string, string, error) {
		return run(a)
	})
}

// RegisterStream is Register for tools that emit display-only output
// while running; a nil emit means the caller is not streaming.
func RegisterStream[T any](name, description string, run func(args *T, emit StreamFunc) (result, ui string, err error)) {
	r := &jsonschema.Reflector{ExpandedStruct: true} // inline, no $ref/$defs: providers accept plain schemas
	s := r.Reflect(new(T))
	s.Version = "" // omit $schema; providers do not need it
	schemaJSON, err := json.Marshal(s)
	if err != nil {
		panic(fmt.Sprintf("tools: %s: reflect schema: %v", name, err))
	}
	doc, err := schema.UnmarshalJSON(bytes.NewReader(schemaJSON))
	if err != nil {
		panic(fmt.Sprintf("tools: %s: parse schema: %v", name, err))
	}
	c := schema.NewCompiler()
	if err := c.AddResource("schema.json", doc); err != nil {
		panic(fmt.Sprintf("tools: %s: %v", name, err))
	}
	compiled, err := c.Compile("schema.json")
	if err != nil {
		panic(fmt.Sprintf("tools: %s: compile schema: %v", name, err))
	}
	validated := func(raw json.RawMessage, emit StreamFunc) (string, string, error) {
		var v any
		if err := json.Unmarshal(raw, &v); err != nil {
			return "", "", fmt.Errorf("invalid arguments: %v", err)
		}
		if err := compiled.Validate(v); err != nil {
			// The model sees this and can correct its call.
			return "", "", fmt.Errorf("invalid arguments: %v", err)
		}
		var args T
		if err := json.Unmarshal(raw, &args); err != nil {
			return "", "", fmt.Errorf("invalid arguments: %v", err)
		}
		return run(&args, emit)
	}
	registry[name] = &Tool{
		Name:        name,
		Description: description,
		Schema:      schemaJSON,
		compiled:    compiled,
		run:         func(raw json.RawMessage) (string, string, error) { return validated(raw, nil) },
		runStream:   validated,
	}
}

// Get returns a tool by name.
func Get(name string) (*Tool, bool) {
	t, ok := registry[name]
	return t, ok
}

// Truncated reports whether the named tool's last run cut its result
// (tail kept, beginning dropped). Only streaming tools that truncate
// (bash) report; everything else returns false.
func Truncated(name string) bool {
	if name == "bash" {
		return lastTruncated
	}
	return false
}

// Streams reports whether the tool emits display-only chunks when given
// a non-nil emit (i.e. was registered with RegisterStream semantics).
func (t *Tool) Streams() bool {
	return t.runStream != nil
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

// ─── Running process groups ──────────────────────────────────────────────────

var (
	runningMu sync.Mutex
	running   = map[int]bool{}
)

func track(pgid int)   { runningMu.Lock(); running[pgid] = true; runningMu.Unlock() }
func untrack(pgid int) { runningMu.Lock(); delete(running, pgid); runningMu.Unlock() }

// KillAll SIGKILLs every tracked tool process group; used on interrupt so
// :PitelStop takes in-flight commands down with the binary.
func KillAll() {
	runningMu.Lock()
	defer runningMu.Unlock()
	for pgid := range running {
		syscall.Kill(-pgid, syscall.SIGKILL)
	}
}
