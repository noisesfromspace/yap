package utils

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
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
