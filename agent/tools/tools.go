// Package tools holds ONLY the agent's callable tools — nothing else.
// Every non-test Go file in this directory except tools.go (the registry
// below) defines exactly one tool: one file per tool, each self-registering
// via Register in init(). Adding or changing a tool = editing a file here
// and recompiling (CGO_ENABLED=0).
//
// A tool defines an Args struct; the JSON schema sent to the provider is
// generated from it by reflection (invopop/jsonschema), and incoming
// model arguments are validated against the compiled schema
// (santhosh-tekuri/jsonschema) before Run is called — hand-written
// schemas and raw unmarshal errors are both gone.
//
// Helpers do NOT belong here, even when only tools call them. Shared
// helpers (path guarding, SSRF checks, secret scrubbing, safety scanning,
// unified diffs, events, process-group tracking, arg slimming) live in
// agent/utils. If you are adding something that does not call Register,
// it goes in agent/utils.
package tools

import (
	"bytes"
	"encoding/json"
	"fmt"
	"sort"

	"github.com/invopop/jsonschema"
	schema "github.com/santhosh-tekuri/jsonschema/v6"

	"boers.email/yap/agent/utils"
)

// Tool is a single callable tool. result is sent back to the model; ui is
// an optional display-only payload for the buffer (yap:ui, R-tool-region).
type Tool struct {
	Name        string
	Description string
	Schema      json.RawMessage // generated from the tool's Args struct
	run         func(args json.RawMessage) (result, ui string, err error)
	close       func()
	// Alert-gate metadata (see utils/alert.go). gateTier defaults to
	// TierSilent when Gate is never called; preflight runs deterministic
	// checks and returns a non-empty hard-block reason, or "" to defer to
	// the tier's decision.
	gateTier  utils.Tier
	preflight func(args json.RawMessage) string
}

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
		run:         validated,
	}
	if len(cleanup) > 0 {
		registry[name].close = cleanup[0]
	}
}

// Get returns a tool by name.
func Get(name string) (*Tool, bool) {
	t, ok := registry[name]
	return t, ok
}

// Gate configures the pre-execution alert gate for a tool, called from the
// tool file's init() after Register. tier selects how much scrutiny the call
// gets; preflight (optional) runs deterministic checks and returns a
// non-empty reason to hard-block the call regardless of the decision model.
func Gate(name string, tier utils.Tier, preflight func(args json.RawMessage) string) {
	if t, ok := registry[name]; ok {
		t.gateTier = tier
		t.preflight = preflight
	}
}

// Assess runs a tool's deterministic preflight and returns its tier plus any
// hard-block reason. Unknown tools are treated as silent; the caller reports
// the unknown-tool error.
func Assess(name string, args json.RawMessage) (utils.Tier, string) {
	t, ok := registry[name]
	if !ok {
		return utils.TierSilent, ""
	}
	if t.preflight == nil {
		return t.gateTier, ""
	}
	return t.gateTier, t.preflight(args)
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

// CloseAll releases resources held by registered tools before backend exit.
func CloseAll() {
	for _, t := range All() {
		if t.close != nil {
			t.close()
		}
	}
}
