package tools

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/wire"
)

func TestSubagentTimeout(t *testing.T) {
	oldReplies, oldWait := SubagentReplies, subagentWait
	SubagentReplies = make(map[string]chan SubagentReply)
	subagentWait = time.Millisecond
	defer func() { SubagentReplies, subagentWait = oldReplies, oldWait }()
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
	oldReplies, oldWait := SubagentReplies, subagentWait
	oldID := subagentID.Load()
	SubagentReplies = make(map[string]chan SubagentReply)
	subagentWait = 250 * time.Millisecond
	subagentID.Store(0)
	defer func() {
		SubagentReplies, subagentWait = oldReplies, oldWait
		subagentID.Store(oldID)
	}()
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

func TestSubagentStopUnblocks(t *testing.T) {
	oldReplies, oldStop, oldWait := SubagentReplies, SubagentStop, subagentWait
	oldID := subagentID.Load()
	SubagentReplies = make(map[string]chan SubagentReply)
	SubagentStop = make(chan struct{}, 1)
	subagentWait = time.Minute
	subagentID.Store(0)
	defer func() {
		SubagentReplies, SubagentStop, subagentWait = oldReplies, oldStop, oldWait
		subagentID.Store(oldID)
	}()
	tool, _ := Get("subagent")
	done := make(chan error, 1)
	go func() {
		_, _, err := tool.Run([]byte(`{"agent":"scout","task":"t","tools":["read"]}`))
		done <- err
	}()
	// Confirm the path before signalling stop (a few deliveries so one lands
	// after the reply channel is registered), then stop and expect the wait to
	// abort immediately with the session link preserved.
	for i := 0; i < 20; i++ {
		DeliverSubagentReply(SubagentReply{ID: "1", Path: "/tmp/child.md"})
		time.Sleep(5 * time.Millisecond)
	}
	SubagentStop <- struct{}{}
	select {
	case err := <-done:
		if err == nil || !strings.Contains(err.Error(), "subagent cancelled") || !strings.Contains(err.Error(), "/tmp/child.md") {
			t.Fatalf("expected cancellation with path, got %v", err)
		}
	case <-time.After(2 * time.Second):
		t.Fatal("subagent tool did not unblock on stop")
	}
}

func TestSubagentModelForwarded(t *testing.T) {
	var buf bytes.Buffer
	oldWriter := wire.SetFrameWriter(&buf)
	oldReplies, oldWait := SubagentReplies, subagentWait
	SubagentReplies = make(map[string]chan SubagentReply)
	subagentWait = time.Millisecond
	defer func() {
		wire.SetFrameWriter(oldWriter)
		SubagentReplies, subagentWait = oldReplies, oldWait
	}()
	tool, _ := Get("subagent")
	_, _, _ = tool.Run([]byte(`{"agent":"scout","model":"openai/gpt-5-mini","task":"t","tools":["read","mcp_example_query"]}`))
	if ev := buf.String(); !strings.Contains(ev, `"type":"subagent_request"`) ||
		!strings.Contains(ev, `"model":"openai/gpt-5-mini"`) ||
		!strings.Contains(ev, `"tools":["read","mcp_example_query"]`) {
		t.Fatalf("per-call model not forwarded to the request event: %q", ev)
	}
}
