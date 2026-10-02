package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	"boers.email/yap/agent/providers"
)

func TestMarshalCommentJSON(t *testing.T) {
	cmd := "grep x | awk 'NR>=57 && NR<=152' ; echo '-->'"
	got := string(marshalCommentJSON(map[string]any{"command": cmd}, ""))

	if strings.Contains(got, `\u0026`) {
		t.Fatalf("& should be literal, not escaped: %s", got)
	}
	if !strings.Contains(got, "&&") || !strings.Contains(got, "<=") || !strings.Contains(got, ">=") {
		t.Fatalf("&, <, > should be literal: %s", got)
	}
	if strings.Contains(got, "-->") {
		t.Fatalf("literal --> must be guarded: %s", got)
	}
	if !strings.Contains(got, `--\u003e`) {
		t.Fatalf("--> must be guarded so it cannot close the comment: %s", got)
	}
	// Decoding must yield the original command, so the flattened transcript
	// the model sees on later turns is unchanged.
	var back map[string]any
	if err := json.Unmarshal([]byte(got), &back); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if back["command"] != cmd {
		t.Fatalf("round-trip corrupted command: %q", back["command"])
	}
}

func TestMarshalCommentJSONStyleTag(t *testing.T) {
	cmd := "echo '<style>body{x:y}</style>'"
	got := string(marshalCommentJSON(map[string]any{"command": cmd}, ""))

	if strings.Contains(got, "<style") {
		t.Fatalf("raw <style must be neutralized: %s", got)
	}
	if !strings.Contains(got, `\u003cstyle>`) {
		t.Fatalf("expected \\u003cstyle escape: %s", got)
	}
	var back map[string]any
	if err := json.Unmarshal([]byte(got), &back); err != nil {
		t.Fatalf("decode: %v", err)
	}
	if back["command"] != cmd {
		t.Fatalf("round-trip corrupted command: %q", back["command"])
	}
}

func TestEmitToolHeaderNoHTMLEscaping(t *testing.T) {
	var buf bytes.Buffer
	out := bufio.NewWriter(&buf)
	emitToolHeader(out, providers.ToolCall{
		ID:    "c1",
		Name:  "bash",
		Input: json.RawMessage(`{"command":"grep x | awk 'NR>=57 && NR<=152' ; echo '-->'"}`),
	})
	out.Flush()
	s := buf.String()

	if strings.Contains(s, `\u0026`) || strings.Contains(s, `\u003c`) {
		t.Fatalf("header should keep & and < literal: %s", s)
	}
	if !strings.Contains(s, `--\u003e`) {
		t.Fatalf("header must guard -->: %s", s)
	}
}
