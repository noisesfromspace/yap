package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"
	"testing"

	"boers.email/yap/agent/turn"
	"boers.email/yap/agent/wire"
)

func TestBoundaryQueueCoalescesAndClears(t *testing.T) {
	ch := make(chan boundaryUpdate, 4)
	q := boundaryQueue{updates: ch}
	ch <- boundaryUpdate{steer: "first"}
	ch <- boundaryUpdate{provider: "a", model: "old"}
	ch <- boundaryUpdate{provider: "b", model: "new"}
	ch <- boundaryUpdate{steer: "last"}
	if got, want := q.poll(), (turn.Boundary{Provider: "b", Model: "new", Steer: "last"}); got != want {
		t.Fatalf("poll = %+v, want %+v", got, want)
	}
	if got := q.poll(); got != (turn.Boundary{}) {
		t.Fatalf("previous updates repeated: %+v", got)
	}
	ch <- boundaryUpdate{steer: "cancel me"}
	ch <- boundaryUpdate{steer: ""}
	if got := q.poll(); got != (turn.Boundary{}) {
		t.Fatalf("empty steer should clear pending text: %+v", got)
	}
}

func TestEmitTerminalFrames(t *testing.T) {
	for _, tc := range []struct {
		name string
		err  error
		want []string
	}{
		{"success", nil, []string{"turn_complete"}},
		{"cancel", fmt.Errorf("stopped: %w", context.Canceled), []string{"turn_complete"}},
		{"failure", wire.CodedError{Code: wire.CodeInvalidParam, Err: errors.New("bad params")}, []string{"event", "turn_complete"}},
	} {
		t.Run(tc.name, func(t *testing.T) {
			var out bytes.Buffer
			old := wire.SetFrameWriter(&out)
			defer wire.SetFrameWriter(old)
			emitTerminal(tc.err)
			lines := strings.Split(strings.TrimSpace(out.String()), "\n")
			if len(lines) != len(tc.want) {
				t.Fatalf("frames: %s", out.String())
			}
			for i, line := range lines {
				var frame map[string]any
				if err := json.Unmarshal([]byte(line), &frame); err != nil {
					t.Fatal(err)
				}
				if frame["type"] != tc.want[i] {
					t.Fatalf("frame order: %s", out.String())
				}
				if tc.name == "cancel" && frame["cancelled"] != true {
					t.Fatalf("cancel frame: %s", out.String())
				}
				if tc.name == "failure" && i == 0 && frame["event"].(map[string]any)["code"] != float64(wire.CodeInvalidParam) {
					t.Fatalf("wrong audit code: %s", out.String())
				}
			}
		})
	}
}
