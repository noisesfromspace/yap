package utils

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
)

// eventOut receives `yap:event {json}` lines for the Lua side (a var
// so tests can capture it). Kept separate from stdout, which carries
// buffer content. Events are the audit trail: tool calls (full
// arguments), results, and turn summaries — the Lua side appends them
// to the session's audit log.
var eventOut io.Writer = os.Stderr
var eventMu sync.Mutex

// EmitEvent writes one yap:event line (JSON) to eventOut.
func EmitEvent(v any) {
	// Events land in the JSONL audit log and the plain-text audit view buffer,
	// never inside an HTML comment, so HTML-escaping only mangles the raw
	// log (`&&` -> `\u0026`). Skip it; keep `&`/`<`/`>` readable.
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v) // event payloads are built by yap and cannot fail
	b := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
	eventMu.Lock()
	defer eventMu.Unlock()
	fmt.Fprintf(eventOut, "yap:event %s\n", b)
}

// SetEventWriter swaps the event sink and returns the previous one. It is
// primarily useful to make the stdout/event ordering contract testable.
func SetEventWriter(w io.Writer) io.Writer {
	eventMu.Lock()
	defer eventMu.Unlock()
	old := eventOut
	eventOut = w
	return old
}
