package wire

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

type decisionReplyWriter struct {
	reply  *ApprovalReply
	frames bytes.Buffer
}

func (w *decisionReplyWriter) Write(p []byte) (int, error) {
	var frame struct{ Type, ID string }
	if json.Unmarshal(p, &frame) == nil && frame.Type == "approval_request" && w.reply != nil {
		r := *w.reply
		r.ID = frame.ID
		ApprovalReplies <- r
	}
	return w.frames.Write(p)
}

func TestApprovalDecisionCapture(t *testing.T) {
	oldSeq := approvalSeq.Load()
	defer approvalSeq.Store(oldSeq)
	oldReplies, oldTimeout := ApprovalReplies, approvalTimeout
	ApprovalReplies = make(chan ApprovalReply, 2)
	approvalTimeout = time.Millisecond
	defer func() { ApprovalReplies, approvalTimeout = oldReplies, oldTimeout }()
	for _, tc := range []struct {
		outcome, label string
		reply          *ApprovalReply
	}{
		{"approved", "Approved by you", &ApprovalReply{Approved: true, TS: "2026-01-02T03:04:05Z"}},
		{"denied", "Denied by you", &ApprovalReply{}},
		{"auto-approved", "Auto-approved", &ApprovalReply{Approved: true, Auto: true}},
		{"timeout", "Approval timed out", nil},
	} {
		t.Run(tc.outcome, func(t *testing.T) {
			w := &decisionReplyWriter{reply: tc.reply}
			oldWriter := SetFrameWriter(w)
			defer SetFrameWriter(oldWriter)
			finish := CaptureApprovalDecisions()
			before := time.Now()
			RequestApproval("private command", "bash", "guard rule")
			decisions := finish()
			if len(decisions) != 1 {
				t.Fatalf("decisions: %#v", decisions)
			}
			d := decisions[0]
			ts, err := time.Parse(time.RFC3339Nano, d.TS)
			if err != nil || !strings.HasSuffix(d.TS, "Z") {
				t.Fatalf("decision timestamp: %q (%v)", d.TS, err)
			}
			if tc.reply != nil && tc.reply.TS != "" {
				if d.TS != tc.reply.TS {
					t.Fatalf("decision timestamp was not preserved: %s", d.TS)
				}
			} else if ts.Before(before) || ts.After(time.Now()) {
				t.Fatalf("decision timestamp not captured at decision: %s", d.TS)
			}
			if d.Type != "guard_decision" || d.Outcome != tc.outcome || d.Text != tc.label+" · bash" || d.ID == "" || d.Tool != "bash" || d.Reason != "guard rule" {
				t.Fatalf("decision: %#v", d)
			}
			// Capturing metadata must not insert extra frames into the audit stream.
			lines := strings.Count(w.frames.String(), "\n")
			want := 1
			if tc.outcome == "timeout" {
				want = 2
			}
			if lines != want {
				t.Fatalf("changed audit frames: %s", &w.frames)
			}
			next := CaptureApprovalDecisions()
			if got := next(); len(got) != 0 {
				t.Fatalf("leaked decisions: %#v", got)
			}
		})
	}
}
