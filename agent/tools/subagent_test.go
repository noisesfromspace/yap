package tools

import (
	"bytes"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/utils"
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

func TestSubagentModelForwarded(t *testing.T) {
	var buf bytes.Buffer
	oldWriter := utils.SetEventWriter(&buf)
	oldReplies, oldWait := SubagentReplies, subagentWait
	SubagentReplies = make(chan SubagentReply, 1)
	subagentWait = time.Millisecond
	defer func() {
		utils.SetEventWriter(oldWriter)
		SubagentReplies, subagentWait = oldReplies, oldWait
	}()
	tool, _ := Get("subagent")
	_, _, _ = tool.Run([]byte(`{"agent":"scout","model":"openai/gpt-5-mini","task":"t"}`))
	if ev := buf.String(); !strings.Contains(ev, `"type":"subagent_request"`) ||
		!strings.Contains(ev, `"model":"openai/gpt-5-mini"`) {
		t.Fatalf("per-call model not forwarded to the request event: %q", ev)
	}
}
