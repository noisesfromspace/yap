package tools

import (
	"strings"
	"testing"
	"time"
)

func TestSubagentTimeout(t *testing.T) {
	oldReplies, oldWait := SubagentReplies, subagentWait
	SubagentReplies = make(chan SubagentReply, 1)
	subagentWait = time.Millisecond
	defer func() { SubagentReplies, subagentWait = oldReplies, oldWait }()
	tool, ok := Get("subagent")
	if !ok {
		t.Fatal("subagent tool missing")
	}
	_, _, err := tool.Run([]byte(`{"agent":"scout","task":"test"}`))
	if err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("expected timeout, got %v", err)
	}
}
