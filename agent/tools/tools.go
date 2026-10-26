// Package tools holds ONLY the agent's callable tools — nothing else.
// Every non-test Go file in this directory except tools.go (the registry
// below) defines exactly one tool, self-registering via Register in init().
// Adding or changing a tool = editing a file here and recompiling
// (CGO_ENABLED=0). MCP tools are not files here: they are discovered at
// runtime from configured servers and registered through RegisterRaw by the
// turn loop.
//
// A tool defines an Args struct; the JSON schema sent to the provider is
// generated from it by reflection (invopop/jsonschema), and incoming
// model arguments are validated against the compiled schema
// (santhosh-tekuri/jsonschema) before Run is called — hand-written
// schemas and raw unmarshal errors are both gone.
//
// Each tool may also declare static guard rules with Gate in its init().
// A rule is a named, deterministic condition that pauses the call for a
// human Run/Deny decision before it runs. Rules are declared next to the
// tool they guard (in the tool's own source file), and every registered
// rule is surfaced automatically by `yap guard` and the frontend's guard
// board — adding one is a one-file change plus a recompile.
//
// Helpers do NOT belong here, even when only tools call them. Shared
// helpers (path resolution, SSRF checks, secret scrubbing + the secrets
// guard, unified diffs, events, process-group tracking, arg slimming, the
// static rule matcher) live in agent/wire, agent/safety and agent/utils. If
// you are adding something that does not call Register or Gate, it goes in
// one of those packages.
package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"
	"strings"
	"sync"

	"github.com/invopop/jsonschema"
	schema "github.com/santhosh-tekuri/jsonschema/v6"

	"boers.email/yap/agent/safety"
)

// Tool is a single callable tool. result is sent back to the model; ui is
// an optional display-only payload for the buffer (yap:ui, R-tool-region).
type Tool struct {
	Name        string
	Description string
	Schema      json.RawMessage // generated from the tool's Args struct
	run         func(args json.RawMessage) (result, ui string, err error)
	close       func()
}

var registryMu sync.RWMutex

var registry = map[string]*Tool{}

// Run executes the tool's validated run function.
func (t *Tool) Run(args json.RawMessage) (result, ui string, err error) {
	return t.run(args)
}

// Register adds a tool; called from each tool file's init(). T is the
// tool's argument struct: json tags name the parameters (omitempty =
// optional), jsonschema tags carry descriptions. Stateful tools may pass a
// cleanup function, which is called on backend shutdown.
func Register[T any](name, description string, run func(args *T) (result, ui string, err error), cleanup ...func()) {
	// Inline every nested struct; do not emit $defs/$ref. Moonshot's
	// schema validator rejects $ref to $defs as "infinite recursion
	// without termination condition".
	r := &jsonschema.Reflector{ExpandedStruct: true, DoNotReference: true}
	s := r.Reflect(new(T))
	s.Version = "" // omit $schema; providers do not need it
	schemaJSON, err := json.Marshal(s)
	if err != nil {
		panic(fmt.Sprintf("tools: %s: reflect schema: %v", name, err))
	}
	validate, err := compileSchema(schemaJSON)
	if err != nil {
		panic(fmt.Sprintf("tools: %s: %v", name, err))
	}
	validated := func(raw json.RawMessage) (string, string, error) {
		if err := validate(raw); err != nil {
			return "", "", err
		}
		var args T
		if err := json.Unmarshal(raw, &args); err != nil {
			return "", "", fmt.Errorf("invalid arguments: %v", err)
		}
		return run(&args)
	}
	registryMu.Lock()
	defer registryMu.Unlock()
	registry[name] = &Tool{
		Name:        name,
		Description: description,
		Schema:      schemaJSON,
		run:         validated,
	}
	if len(cleanup) > 0 {
		registry[name].close = cleanup[0]
	}
}

// compileSchema compiles a JSON schema and returns a validator over raw
// arguments. The validator returns a model-readable error when the arguments
// are not valid JSON or fail validation.
func compileSchema(schemaJSON json.RawMessage) (func(json.RawMessage) error, error) {
	doc, err := schema.UnmarshalJSON(bytes.NewReader(schemaJSON))
	if err != nil {
		return nil, err
	}
	c := schema.NewCompiler()
	if err := c.AddResource("schema.json", doc); err != nil {
		return nil, err
	}
	compiled, err := c.Compile("schema.json")
	if err != nil {
		return nil, err
	}
	return func(raw json.RawMessage) error {
		var v any
		if err := json.Unmarshal(raw, &v); err != nil {
			return fmt.Errorf("invalid arguments: %v", err)
		}
		if err := compiled.Validate(v); err != nil {
			// The model sees this and can correct its call.
			return fmt.Errorf("invalid arguments: %v", err)
		}
		return nil
	}, nil
}

// RegisterRaw registers a tool whose schema is supplied directly instead of
// reflected from a Go struct. The MCP integration uses it: schemas come from
// external servers at runtime. It returns an error instead of panicking so a
// malformed server schema cannot crash the backend.
func RegisterRaw(name, description string, schemaJSON json.RawMessage, run func(json.RawMessage) (string, string, error), cleanup ...func()) error {
	registryMu.Lock()
	defer registryMu.Unlock()
	if _, exists := registry[name]; exists {
		return fmt.Errorf("tools: %s is already registered", name)
	}
	validate, err := compileSchema(schemaJSON)
	if err != nil {
		return fmt.Errorf("tools: %s: %v", name, err)
	}
	validated := func(raw json.RawMessage) (string, string, error) {
		if err := validate(raw); err != nil {
			return "", "", err
		}
		return run(raw)
	}
	t := &Tool{Name: name, Description: description, Schema: schemaJSON, run: validated}
	if len(cleanup) > 0 {
		t.close = cleanup[0]
	}
	registry[name] = t
	return nil
}

// UnregisterPrefix removes every registered tool whose name starts with
// prefix. The MCP integration calls it before re-registering the turn's
// discovered tools, so tools from a server that went away do not linger.
func UnregisterPrefix(prefix string) {
	registryMu.Lock()
	defer registryMu.Unlock()
	for name := range registry {
		if strings.HasPrefix(name, prefix) {
			delete(registry, name)
		}
	}
}

// Get returns a tool by name.
func Get(name string) (*Tool, bool) {
	registryMu.RLock()
	defer registryMu.RUnlock()
	t, ok := registry[name]
	return t, ok
}

// GuardRule is one registered guard rule, as surfaced to `yap guard` and the
// frontend's guard board.
type GuardRule struct {
	Tool   string `json:"tool"`
	Name   string `json:"name"`
	Always bool   `json:"always,omitempty"`
}

// guardGate is a tool's static rule set: one inspect function that extracts
// the text the rules match on from the tool's arguments, plus the ordered
// rules themselves.
type guardGate struct {
	tool    string
	inspect func(args json.RawMessage) string
	rules   []safety.Rule
}

var guards []guardGate

// Gate registers static approval rules for a tool, called from the tool's
// init() after Register. `inspect` extracts the text the rules match on from
// the tool's typed arguments; a rule with a safety.Shell predicate instead
// parses that text as a shell command line (see safety/shell.go). Rules are
// matched in order and the first match pauses the call for approval. Rules
// live in the tool's source file, so the guard board and `yap guard` pick them
// up automatically.
func Gate[T any](name string, inspect func(*T) string, rules ...safety.Rule) {
	guards = append(guards, guardGate{
		tool:  name,
		rules: rules,
		inspect: func(raw json.RawMessage) string {
			var a T
			if json.Unmarshal(raw, &a) != nil {
				return ""
			}
			return inspect(&a)
		},
	})
}

// Rules returns every registered guard rule sorted by (tool, name), for the
// `yap guard` listing and the frontend guard board.
func Rules() []GuardRule {
	var out []GuardRule
	for _, g := range guards {
		for _, r := range g.rules {
			out = append(out, GuardRule{Tool: g.tool, Name: r.Name, Always: r.Always})
		}
	}
	sort.Slice(out, func(i, j int) bool {
		if out[i].Tool != out[j].Tool {
			return out[i].Tool < out[j].Tool
		}
		return out[i].Name < out[j].Name
	})
	return out
}

// Match returns the name of the first guard rule for tool `name` that trips
// on args, or "" when none do.
func Match(name string, args json.RawMessage) string {
	for _, g := range guards {
		if g.tool != name {
			continue
		}
		if reason := safety.MatchRules(g.rules, g.inspect(args)); reason != "" {
			return reason
		}
	}
	return ""
}

// All returns all registered tools, sorted by name (stable requests).
func All() []*Tool {
	registryMu.RLock()
	defer registryMu.RUnlock()
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

// CloseAll releases resources held by registered tools before backend exit.
func CloseAll() {
	for _, t := range All() {
		if t.close != nil {
			t.close()
		}
	}
}
