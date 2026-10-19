// Package testutil holds the HTTP-server and config helpers shared by the
// agent's test files (a temp settings.json, SSE stub responses, and tool-call
// JSON builders). It lives under internal/ because it is test-only plumbing.
package testutil

import (
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"path/filepath"
	"testing"
)

// WriteConfigJSON writes a full settings.json into a temp config home.
func WriteConfigJSON(t *testing.T, cfg string) {
	t.Helper()
	home := t.TempDir()
	t.Setenv("HOME", home)
	xdg := filepath.Join(home, ".config")
	t.Setenv("XDG_CONFIG_HOME", xdg)
	if err := os.MkdirAll(filepath.Join(xdg, "yap"), 0o755); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(xdg, "yap", "settings.json"), []byte(cfg), 0o644); err != nil {
		t.Fatal(err)
	}
}

// WriteConfig points the binary at a temp HOME with the given providers.
func WriteConfig(t *testing.T, providers string) {
	t.Helper()
	WriteConfigJSON(t, fmt.Sprintf(`{"providers": {%s}}`, providers))
}

// SSE streams the given chunks as an SSE response, then [DONE].
func SSE(w http.ResponseWriter, chunks ...string) {
	w.Header().Set("Content-Type", "text/event-stream")
	for _, c := range chunks {
		fmt.Fprintf(w, "data: %s\n\n", c)
	}
	fmt.Fprint(w, "data: [DONE]\n\n")
}

// TaskCall builds one native tool-call delta map for a fake SSE round.
func TaskCall(id, name string, args any) map[string]any {
	b, _ := json.Marshal(args)
	return map[string]any{"index": 0, "id": id, "type": "function", "function": map[string]string{"name": name, "arguments": string(b)}}
}

// ToolRound writes one SSE chunk carrying the given tool calls.
func ToolRound(w http.ResponseWriter, calls ...map[string]any) {
	for i, c := range calls {
		c["index"] = i
	}
	b, _ := json.Marshal(map[string]any{"choices": []any{map[string]any{"delta": map[string]any{"tool_calls": calls}, "finish_reason": "tool_calls"}}})
	SSE(w, string(b))
}
