package turn

import (
	"encoding/json"
	"strings"
	"testing"
	"time"

	"boers.email/yap/agent/document"
	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/wire"
)

type guardReplyWriter struct{ approved, auto bool }

func (w guardReplyWriter) Write(p []byte) (int, error) {
	var frame struct{ Type, ID string }
	if json.Unmarshal(p, &frame) == nil && frame.Type == "approval_request" {
		wire.ApprovalReplies <- wire.ApprovalReply{ID: frame.ID, Approved: w.approved, Auto: w.auto}
	}
	return len(p), nil
}

func TestGuardDecisionPlacementAndNativeReplay(t *testing.T) {
	// Reuse the native-prefix model: its one tool requests approval just as a
	// sandbox fallback or MCP callback does, without executing any command.
	err := tools.RegisterRaw("missing_test_tool", "test approval", json.RawMessage(`{"type":"object"}`), func(json.RawMessage) (string, string, error) {
		_, err := wire.RequestApproval("test command", "test", "test approval")
		return "tool result unchanged", "", err
	})
	if err != nil {
		t.Fatal(err)
	}
	defer tools.UnregisterPrefix("missing_test_tool")
	oldReplies := wire.ApprovalReplies
	wire.ApprovalReplies = make(chan wire.ApprovalReply, 1)
	defer func() { wire.ApprovalReplies = oldReplies }()
	for _, tc := range []struct {
		outcome        string
		approved, auto bool
	}{
		{"approved", true, false}, {"denied", false, false}, {"auto-approved", true, true},
	} {
		t.Run(tc.outcome, func(t *testing.T) {
			oldWriter := wire.SetFrameWriter(guardReplyWriter{tc.approved, tc.auto})
			defer wire.SetFrameWriter(oldWriter)
			var hist NativeHistory
			var block string
			params := followUpParams(t, &hist, func(s string) string { block = s; return s })
			const opener = "<!-- yap:event "
			start := strings.Index(block, opener)
			end := strings.Index(block, "<!-- /yap:tool -->")
			if start < 0 || end < 0 || strings.TrimSpace(block[end+len("<!-- /yap:tool -->"):start]) != "" {
				t.Fatalf("decision not immediately after tool region: %s", block)
			}
			line := strings.SplitN(block[start:], "\n", 2)[0]
			var decision wire.ApprovalDecision
			if err := json.Unmarshal([]byte(strings.TrimSuffix(strings.TrimPrefix(line, opener), " -->")), &decision); err != nil {
				t.Fatal(err)
			}
			if decision.Outcome != tc.outcome || decision.Type != "guard_decision" || decision.Text == "" {
				t.Fatalf("decision: %#v", decision)
			}
			if _, err := time.Parse(time.RFC3339Nano, decision.TS); err != nil {
				t.Fatal(err)
			}
			for _, msg := range document.Messages("# @assistant\n" + block) {
				if strings.Contains(msg.Content, "guard_decision") {
					t.Fatalf("marker sent as prose: %#v", msg)
				}
			}
			var nativeCall, nativeResult bool
			for _, msg := range params.Messages {
				for _, part := range msg.Content {
					if part.Type == llm.PartToolCall && part.ToolCallID == "c1" {
						nativeCall = true
					}
					if part.Type == llm.PartToolResult && part.ToolCallID == "c1" {
						nativeResult = true
						if part.ToolOutput != "tool result unchanged" {
							t.Fatalf("native result changed: %q", part.ToolOutput)
						}
					}
					if strings.Contains(part.Text, "guard_decision") {
						t.Fatal("decision leaked into native history")
					}
				}
			}
			if !nativeCall || !nativeResult {
				t.Fatalf("native replay lost: call=%v result=%v", nativeCall, nativeResult)
			}
		})
	}
}
