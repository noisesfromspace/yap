// Package wire is the agent's framed wire protocol and turn/process
// runtime: the newline-delimited JSON frame emitter (frames.go), the
// approval request/reply pair (approval.go), streamed tool execution with
// live tool_output/progress frames (toolrun.go), per-turn cancellation
// (turnctx.go), and process-group tracking for interrupting in-flight tool
// processes (procgroup.go).
//
// Everything Go emits to the frontend travels through frames.go; stderr is
// reserved for process logs. One channel means total ordering, so the
// frontend needs no cross-pipe completion barrier.
package wire
