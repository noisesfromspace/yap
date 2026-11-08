package tools

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/wire"
)

// resetSubagentGlobals swaps the subagent package state for one test and
// returns a restore function. Every test that runs the subagent tool must use
// it: the tool registers into all four maps/channels and the counters.
func resetSubagentGlobals() func() {
	oldReplies, oldProgress := SubagentReplies, SubagentProgresses
	oldWait, oldInactivity := subagentWait, subagentInactivityWait
	oldID := subagentID.Load()
	SubagentReplies = make(map[string]chan SubagentReply)
	SubagentProgresses = make(map[string]chan SubagentProgress)
	subagentID.Store(0)
	return func() {
		SubagentReplies, SubagentProgresses = oldReplies, oldProgress
		subagentWait, subagentInactivityWait = oldWait, oldInactivity
		subagentID.Store(oldID)
	}
}

func TestSubagentTimeout(t *testing.T) {
	restore := resetSubagentGlobals()
	defer restore()
	subagentWait = time.Millisecond
	subagentInactivityWait = time.Second
	tool, ok := Get("subagent")
	if !ok {
		t.Fatal("subagent tool missing")
	}
	_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test","tools":["read"]}`))
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("expected timeout, got %v", err)
	}
}

func TestSubagentTimeoutKeepsPath(t *testing.T) {
	restore := resetSubagentGlobals()
	defer restore()
	subagentWait = 250 * time.Millisecond
	subagentInactivityWait = time.Second
	tool, _ := Get("subagent")
	done := make(chan error, 1)
	go func() {
		_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test","tools":["read"]}`))
		done <- err
	}()
	// id 1 is the first request after the reset. Deliver the path a few times
	// so the delivery after the reply channel is registered is kept; duplicate
	// path-only frames are harmless (the waiter ignores empty results).
	for i := 0; i < 20; i++ {
		DeliverSubagentReply(SubagentReply{ID: "1", Path: "/tmp/child.md"})
		time.Sleep(5 * time.Millisecond)
	}
	err := <-done
	if err == nil || !strings.Contains(err.Error(), "timed out") || !strings.Contains(err.Error(), "/tmp/child.md") {
		t.Fatalf("timeout should keep the child path, got %v", err)
	}
}

func TestSubagentInactivityTimeout(t *testing.T) {
	restore := resetSubagentGlobals()
	defer restore()
	subagentWait = time.Second
	subagentInactivityWait = 40 * time.Millisecond
	tool, _ := Get("subagent")
	_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test","tools":["read"]}`))
	if err == nil || !strings.Contains(err.Error(), "without progress") {
		t.Fatalf("expected inactivity timeout, got %v", err)
	}
}

func TestSubagentProgressResetsDeadline(t *testing.T) {
	restore := resetSubagentGlobals()
	defer restore()
	subagentWait = time.Second
	subagentInactivityWait = 80 * time.Millisecond
	tool, _ := Get("subagent")
	done := make(chan error, 1)
	go func() {
		_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test","tools":["read"]}`))
		done <- err
	}()
	// Keep the child "alive" well past the 80ms inactivity window; without the
	// reset the inactivity clock would fire almost immediately.
	start := time.Now()
	for time.Since(start) < 300*time.Millisecond {
		DeliverSubagentProgress(SubagentProgress{ID: "1", Status: "tool"})
		time.Sleep(10 * time.Millisecond)
	}
	err := <-done
	if time.Since(start) < 280*time.Millisecond {
		t.Fatalf("inactivity fired too early (%v): progress did not reset the deadline", time.Since(start))
	}
	if err == nil || !strings.Contains(err.Error(), "without progress") {
		t.Fatalf("expected inactivity timeout after progress stopped, got %v", err)
	}
}

func TestSubagentApprovalSuspendsInactivity(t *testing.T) {
	restore := resetSubagentGlobals()
	defer restore()
	subagentWait = 300 * time.Millisecond
	subagentInactivityWait = 50 * time.Millisecond
	tool, _ := Get("subagent")
	done := make(chan error, 1)
	go func() {
		_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test","tools":["read"]}`))
		done <- err
	}()
	// Deliver approval repeatedly so at least one lands after registration.
	// With the clock suspended, only the hard cap can fire.
	for i := 0; i < 8; i++ {
		DeliverSubagentProgress(SubagentProgress{ID: "1", Status: "approval"})
		time.Sleep(5 * time.Millisecond)
	}
	err := <-done
	if err == nil || strings.Contains(err.Error(), "without progress") {
		t.Fatalf("approval should suspend the inactivity clock, got %v", err)
	}
	if !strings.Contains(err.Error(), "timed out after") {
		t.Fatalf("expected the hard deadline, got %v", err)
	}
}

func TestSubagentModelForwarded(t *testing.T) {
	var buf bytes.Buffer
	oldWriter := wire.SetFrameWriter(&buf)
	restore := resetSubagentGlobals()
	defer func() {
		wire.SetFrameWriter(oldWriter)
		restore()
	}()
	subagentWait = time.Millisecond
	subagentInactivityWait = time.Second
	tool, _ := Get("subagent")
	_, _, _ = tool.Run([]byte(`{"agent":"scout","model":"openai/gpt-5-mini","task":"t","tools":["read","mcp_example_query"]}`))
	if ev := buf.String(); !strings.Contains(ev, `"type":"subagent_request"`) ||
		!strings.Contains(ev, `"model":"openai/gpt-5-mini"`) ||
		!strings.Contains(ev, `"tools":["read","mcp_example_query"]`) {
		t.Fatalf("per-call model not forwarded to the request event: %q", ev)
	}
}
