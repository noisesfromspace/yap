// Package tools holds yap's built-in tools: one file per tool, each
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
	"io"
	"os"
	"sort"
	"sync"
	"syscall"

	"github.com/invopop/jsonschema"
	schema "github.com/santhosh-tekuri/jsonschema/v6"
)

// eventOut receives `yap:event {json}` lines for the Lua side (a var
// so tests can capture it). Kept separate from stdout, which carries
// buffer content. Events are the audit trail: tool calls (full
// arguments), results, and turn summaries — the Lua side appends them
// to the session's audit log.
var eventOut io.Writer = os.Stderr

// EmitEvent writes one yap:event line (JSON) to eventOut.
func EmitEvent(v any) {
	b, _ := json.Marshal(v)
	fmt.Fprintf(eventOut, "yap:event %s\n", b)
}

// SetEventWriter swaps the event sink and returns the previous one. It is
// primarily useful to make the stdout/event ordering contract testable.
func SetEventWriter(w io.Writer) io.Writer {
	old := eventOut
	eventOut = w
	return old
}

// Tool is a single callable tool. result is sent back to the model; ui is
// an optional display-only payload for the buffer (yap:ui, R12).
type Tool struct {
	Name        string
	Description string
	Schema      json.RawMessage // generated from the tool's Args struct
	compiled    *schema.Schema
	run         func(args json.RawMessage) (result, ui string, err error)
}

var registry = map[string]*Tool{}

// Run executes the tool's validated run function.
func (t *Tool) Run(args json.RawMessage) (result, ui string, err error) {
	return t.run(args)
}

// Register adds a tool; called from each tool file's init(). T is the
// tool's argument struct: json tags name the parameters (omitempty =
// optional), jsonschema tags carry descriptions.
func Register[T any](name, description string, run func(args *T) (result, ui string, err error)) {
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
	validated := func(raw json.RawMessage) (string, string, error) {
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
		return run(&args)
	}
	registry[name] = &Tool{
		Name:        name,
		Description: description,
		Schema:      schemaJSON,
		compiled:    compiled,
		run:         validated,
	}
}

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

// ─── Running process groups ──────────────────────────────────────────────────

var (
	runningMu sync.Mutex
	running   = map[int]bool{}
)

func track(pgid int)   { runningMu.Lock(); running[pgid] = true; runningMu.Unlock() }
func untrack(pgid int) { runningMu.Lock(); delete(running, pgid); runningMu.Unlock() }

// KillAll SIGKILLs every tracked tool process group; used on interrupt so
// :YapStop takes in-flight commands down with the binary.
func KillAll() {
	runningMu.Lock()
	defer runningMu.Unlock()
	for pgid := range running {
		syscall.Kill(-pgid, syscall.SIGKILL)
	}
}
