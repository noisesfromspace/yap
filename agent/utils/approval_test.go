package utils

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"
	"time"
)

func TestRequestApproval(t *testing.T) {
	// No channel (yap send, unit tests): denied with an error.
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion", Decision{}); ok || err == nil || !strings.Contains(err.Error(), "serve") {
		t.Fatalf("nil channel: ok=%v err=%v", ok, err)
	}

	old := ApprovalReplies
	ApprovalReplies = make(chan ApprovalReply, 1)
	defer func() { ApprovalReplies = old }()

	// Denied.
	var events bytes.Buffer
	oldWriter := SetEventWriter(&events)
	defer SetEventWriter(oldWriter)
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-1", Approved: false} }()
	dec := Decision{PAlert: 0.91, Severity: 2.7, Confidence: 0.74, SeverityProbabilities: map[string]float64{"2": 0.9}}
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion", dec); ok || err != nil {
		t.Fatalf("deny: ok=%v err=%v", ok, err)
	}
	var event struct {
		Type              string  `json:"type"`
		Tool              string  `json:"tool"`
		Reason            string  `json:"reason"`
		Command           string  `json:"command"`
		PAlert            float64 `json:"p_alert"`
		Severity          float64 `json:"severity"`
		Confidence        float64 `json:"confidence"`
		SeverityCategory  string  `json:"severity_category"`
		SeverityBreakdown string  `json:"severity_breakdown"`
	}
	line := strings.TrimPrefix(strings.TrimSpace(events.String()), "yap:event ")
	if err := json.Unmarshal([]byte(line), &event); err != nil {
		t.Fatalf("decode approval audit event: %v", err)
	}
	if event.Type != "approval_request" || event.Tool != "bash" || event.Reason != "recursive or forced deletion" || event.Command != "rm -rf /" {
		t.Fatalf("approval audit event mismatch: %+v", event)
	}
	if event.PAlert != 0.91 || event.Severity != 2.7 || event.Confidence != 0.74 || event.SeverityCategory != "destructive" || event.SeverityBreakdown != "destructive 90%" {
		t.Fatalf("approval audit event lacks decision fields: %+v", event)
	}

	// Approved.
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-2", Approved: true} }()
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion", Decision{}); !ok || err != nil {
		t.Fatalf("approve: ok=%v err=%v", ok, err)
	}

	// Timeout denies.
	oldTimeout := approvalTimeout
	approvalTimeout = 30 * time.Millisecond
	defer func() { approvalTimeout = oldTimeout }()
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion", Decision{}); ok || err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("timeout: ok=%v err=%v", ok, err)
	}
}
