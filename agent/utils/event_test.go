package utils

import (
	"bytes"
	"strings"
	"testing"
)

func TestEmitEventNoHTMLEscaping(t *testing.T) {
	var buf bytes.Buffer
	old := SetEventWriter(&buf)
	defer SetEventWriter(old)

	EmitEvent(map[string]any{"type": "tool_call", "command": "grep x | awk 'NR>=57 && NR<=152'"})

	got := buf.String()
	if !strings.HasPrefix(got, "yap:event ") {
		t.Fatalf("malformed event line: %q", got)
	}
	if strings.Contains(got, `\u0026`) || strings.Contains(got, `\u003c`) || strings.Contains(got, `\u003e`) {
		t.Fatalf("event should keep &, <, > literal: %q", got)
	}
	if !strings.Contains(got, "&&") {
		t.Fatalf("expected literal && in event: %q", got)
	}
}
