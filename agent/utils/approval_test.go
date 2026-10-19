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
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion"); ok || err == nil || !strings.Contains(err.Error(), "serve") {
		t.Fatalf("nil channel: ok=%v err=%v", ok, err)
	}

	old := ApprovalReplies
	ApprovalReplies = make(chan ApprovalReply, 1)
	defer func() { ApprovalReplies = old }()

	// Denied.
	var events bytes.Buffer
	oldWriter := SetFrameWriter(&events)
	defer SetFrameWriter(oldWriter)
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-1", Approved: false} }()
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion"); ok || err != nil {
		t.Fatalf("deny: ok=%v err=%v", ok, err)
	}
	var frame struct {
		Type    string `json:"type"`
		Tool    string `json:"tool"`
		Reason  string `json:"reason"`
		Command string `json:"command"`
	}
	if err := json.Unmarshal(events.Bytes(), &frame); err != nil {
		t.Fatalf("decode approval request frame: %v", err)
	}
	if frame.Type != "approval_request" || frame.Tool != "bash" || frame.Reason != "recursive or forced deletion" || frame.Command != "rm -rf /" {
		t.Fatalf("approval request frame mismatch: %+v", frame)
	}

	// Approved.
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-2", Approved: true} }()
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion"); !ok || err != nil {
		t.Fatalf("approve: ok=%v err=%v", ok, err)
	}

	// Timeout denies.
	oldTimeout := approvalTimeout
	approvalTimeout = 30 * time.Millisecond
	defer func() { approvalTimeout = oldTimeout }()
	if ok, err := RequestApproval("rm -rf /", "bash", "recursive or forced deletion"); ok || err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("timeout: ok=%v err=%v", ok, err)
	}
}
