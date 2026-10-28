package wire

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
)

func TestEmitEventFrameNoHTMLEscaping(t *testing.T) {
	var buf bytes.Buffer
	old := SetFrameWriter(&buf)
	defer SetFrameWriter(old)

	EmitEvent(map[string]any{"type": "tool_call", "command": "grep x | awk 'NR>=57 && NR<=152'"})

	got := buf.String()
	var frame struct {
		Type  string          `json:"type"`
		Event json.RawMessage `json:"event"`
	}
	if err := json.Unmarshal([]byte(got), &frame); err != nil {
		t.Fatalf("not a JSON frame: %v\n%s", err, got)
	}
	if frame.Type != "event" {
		t.Fatalf("frame type %q, want event", frame.Type)
	}
	if strings.Contains(string(frame.Event), `\u0026`) || strings.Contains(string(frame.Event), `\u003c`) || strings.Contains(string(frame.Event), `\u003e`) {
		t.Fatalf("event should keep &, <, > literal: %s", frame.Event)
	}
	if !strings.Contains(string(frame.Event), "&&") {
		t.Fatalf("expected literal && in event: %s", frame.Event)
	}
}

func TestTextWriterFrames(t *testing.T) {
	var buf bytes.Buffer
	old := SetFrameWriter(&buf)
	defer SetFrameWriter(old)

	w := TextWriter()
	if _, err := w.Write([]byte("hello\nworld")); err != nil {
		t.Fatal(err)
	}

	var frame struct {
		Type string `json:"type"`
		Text string `json:"text"`
	}
	if err := json.Unmarshal(buf.Bytes(), &frame); err != nil {
		t.Fatalf("not a JSON frame: %v\n%s", err, buf.String())
	}
	if frame.Type != "text" || frame.Text != "hello\nworld" {
		t.Fatalf("unexpected text frame: %+v", frame)
	}
}

func TestSideEffectAndCancelledFrames(t *testing.T) {
	var buf bytes.Buffer
	old := SetFrameWriter(&buf)
	defer SetFrameWriter(old)

	EmitCloseSession()
	EmitTurnCancelled()

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected 2 frames, got %d: %q", len(lines), buf.String())
	}
	var c struct {
		Type string `json:"type"`
	}
	if err := json.Unmarshal([]byte(lines[0]), &c); err != nil || c.Type != "close_session" {
		t.Fatalf("bad close_session frame: %v %q", err, lines[0])
	}
	var tc struct {
		Type      string `json:"type"`
		OK        bool   `json:"ok"`
		Cancelled bool   `json:"cancelled"`
	}
	if err := json.Unmarshal([]byte(lines[1]), &tc); err != nil || tc.Type != "turn_complete" || tc.OK || !tc.Cancelled {
		t.Fatalf("bad cancelled frame: %v %q", err, lines[1])
	}
}
