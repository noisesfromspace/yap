package utils

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"sync"
)

// The Go→Lua wire protocol: newline-delimited JSON frames on ONE channel
// (stdout for `yap serve`, stderr for the one-shot `yap send`). Every frame
// carries a `type`; the vocabulary below is the whole protocol. One channel
// means total ordering is structural — the frontend completes a turn only
// when the terminal turn_complete frame arrives, after every text/event/
// tool_output frame before it, with no cross-pipe barrier.
//
// The frame types are:
//   - text              — buffer content (prose + yap markers), append verbatim
//   - event             — audit/UI trail; the nested payload is byte-for-byte
//                         what the old `yap:event` lines carried
//   - tool_output       — streamed bytes of a running tool (live tail)
//   - approval_request  — request: the frontend replies approval_result
//   - subagent_request  — request: the frontend replies subagent_result
//   - turn_complete     — the terminal frame for one turn (ok + error)

// frameOut is the single frame sink (a var so tests can capture it).
var frameOut io.Writer = os.Stderr
var frameMu sync.Mutex

// SetFrameWriter swaps the frame sink and returns the previous one. It is the
// hook tests use to capture the whole framed stream.
func SetFrameWriter(w io.Writer) io.Writer {
	frameMu.Lock()
	defer frameMu.Unlock()
	old := frameOut
	frameOut = w
	return old
}

// writeFrameLocked encodes one frame and writes it to frameOut. The caller
// holds frameMu. HTML-escaping is disabled so `&`, `<`, `>` stay readable in
// the audit log and live tail.
func writeFrameLocked(v any) {
	var buf bytes.Buffer
	enc := json.NewEncoder(&buf)
	enc.SetEscapeHTML(false)
	_ = enc.Encode(v) // frame payloads are built by yap and cannot fail
	b := bytes.TrimSuffix(buf.Bytes(), []byte("\n"))
	fmt.Fprintf(frameOut, "%s\n", b)
}

// TextWriter returns an io.Writer that frames every Write as a `text` frame.
// `yap serve` hands it to the agent loop, so streamed buffer content and the
// control frames below share one ordered channel.
func TextWriter() io.Writer {
	return textFramer{}
}

type textFramer struct{}

func (textFramer) Write(p []byte) (int, error) {
	frameMu.Lock()
	defer frameMu.Unlock()
	writeFrameLocked(map[string]any{"type": "text", "text": string(p)})
	return len(p), nil
}

// EmitEvent writes one `event` frame: the audit/UI trail. The nested payload
// is exactly what the old `yap:event` lines carried, so the Lua handle_event
// routing is unchanged.
func EmitEvent(v any) {
	frameMu.Lock()
	defer frameMu.Unlock()
	writeFrameLocked(map[string]any{"type": "event", "event": v})
}

// EmitToolOutput writes one `tool_output` frame: streamed bytes of a running
// tool, appended to the live tail. Replaces the old temp-file polling.
func EmitToolOutput(log, delta string) {
	frameMu.Lock()
	defer frameMu.Unlock()
	writeFrameLocked(map[string]any{"type": "tool_output", "log": log, "delta": delta})
}

// EmitApprovalRequest writes one `approval_request` frame — a request the
// frontend answers with an approval_result.
func EmitApprovalRequest(id, command, tool, reason string) {
	frameMu.Lock()
	defer frameMu.Unlock()
	writeFrameLocked(map[string]any{"type": "approval_request", "id": id, "command": command, "tool": tool, "reason": reason})
}

// EmitSubagentRequest writes one `subagent_request` frame — a request the
// frontend answers with a subagent_result.
func EmitSubagentRequest(id, agent, model, task, session string) {
	frameMu.Lock()
	defer frameMu.Unlock()
	writeFrameLocked(map[string]any{"type": "subagent_request", "id": id, "agent": agent, "model": model, "task": task, "session": session})
}

// ─── Protocol errors ─────────────────────────────────────────────────────

// Error codes reuse JSON-RPC's ranges as a convention (not compliance), so
// both sides branch on a code instead of string-matching.
const (
	CodeParse        = -32700
	CodeInvalidReq   = -32600
	CodeInvalidParam = -32602
	CodeInternal     = -32603
)

// CodedError carries an error code for a request/params problem, so the
// serve loop can surface it in the structured turn_complete error object.
type CodedError struct {
	Code int
	Err  error
}

func (e CodedError) Error() string {
	if e.Err == nil {
		return ""
	}
	return e.Err.Error()
}

func (e CodedError) Unwrap() error { return e.Err }

// WireError is the structured error object carried by a turn_complete frame.
type WireError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

// EmitTurnComplete writes the terminal frame for one turn. `werr` is nil on
// success; a non-nil CodedError keeps its code, everything else is internal.
func EmitTurnComplete(ok bool, werr *WireError) {
	frameMu.Lock()
	defer frameMu.Unlock()
	m := map[string]any{"type": "turn_complete", "v": 1, "ok": ok}
	if werr != nil {
		m["error"] = werr
	}
	writeFrameLocked(m)
}
