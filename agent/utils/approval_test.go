package utils

import (
	"strings"
	"testing"
	"time"
)

func TestRequestApproval(t *testing.T) {
	// No channel (yap send, unit tests): denied with an error.
	if ok, err := RequestApproval("rm -rf /"); ok || err == nil || !strings.Contains(err.Error(), "serve") {
		t.Fatalf("nil channel: ok=%v err=%v", ok, err)
	}

	old := ApprovalReplies
	ApprovalReplies = make(chan ApprovalReply, 1)
	defer func() { ApprovalReplies = old }()

	// Denied.
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-1", Approved: false} }()
	if ok, err := RequestApproval("rm -rf /"); ok || err != nil {
		t.Fatalf("deny: ok=%v err=%v", ok, err)
	}

	// Approved.
	go func() { ApprovalReplies <- ApprovalReply{ID: "approval-2", Approved: true} }()
	if ok, err := RequestApproval("rm -rf /"); !ok || err != nil {
		t.Fatalf("approve: ok=%v err=%v", ok, err)
	}

	// Timeout denies.
	oldTimeout := approvalTimeout
	approvalTimeout = 30 * time.Millisecond
	defer func() { approvalTimeout = oldTimeout }()
	if ok, err := RequestApproval("rm -rf /"); ok || err == nil || !strings.Contains(err.Error(), "timed out") {
		t.Fatalf("timeout: ok=%v err=%v", ok, err)
	}
}
