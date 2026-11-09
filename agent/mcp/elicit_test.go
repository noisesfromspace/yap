package mcp

import (
	"bytes"
	"encoding/json"
	"strings"
	"testing"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"boers.email/yap/agent/wire"
)

// elicitApproval bridges a server's elicitation request onto the guard gate's
// human Run/Deny: approve maps to the protocol's "accept", deny to "decline",
// and any failure to ask maps to an error so the server refuses the command.
func TestElicitApproval(t *testing.T) {
	// No approval channel (yap send, unit tests): fail closed.
	if _, err := elicitApproval("ssh", &sdk.ElicitRequest{Params: &sdk.ElicitParams{Message: "Confirm x"}}); err == nil {
		t.Fatal("nil channel: want error, got nil")
	}

	old := wire.ApprovalReplies
	wire.ApprovalReplies = make(chan wire.ApprovalReply, 1)
	defer func() { wire.ApprovalReplies = old }()

	var events bytes.Buffer
	oldWriter := wire.SetFrameWriter(&events)
	defer wire.SetFrameWriter(oldWriter)

	// Approved -> accept, with the server's message surfaced as the command
	// the human reads.
	go func() { wire.ApprovalReplies <- wire.ApprovalReply{ID: "approval-1", Approved: true} }()
	res, err := elicitApproval("ssh", &sdk.ElicitRequest{Params: &sdk.ElicitParams{Message: "Confirm destructive command"}})
	if err != nil || res.Action != "accept" {
		t.Fatalf("approve: action=%q err=%v, want accept", res.Action, err)
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
	if frame.Type != "approval_request" || frame.Tool != "mcp:ssh" || frame.Reason != "MCP elicitation" || frame.Command != "Confirm destructive command" {
		t.Fatalf("approval request frame mismatch: %+v", frame)
	}

	// Denied -> decline.
	events.Reset()
	go func() { wire.ApprovalReplies <- wire.ApprovalReply{ID: "approval-2", Approved: false} }()
	res, err = elicitApproval("ssh", &sdk.ElicitRequest{Params: &sdk.ElicitParams{Message: "Confirm destructive command"}})
	if err != nil || res.Action != "decline" {
		t.Fatalf("deny: action=%q err=%v, want decline", res.Action, err)
	}

	// An empty message (URL-mode elicitation) cannot be rendered as a prompt.
	if _, err := elicitApproval("ssh", &sdk.ElicitRequest{Params: &sdk.ElicitParams{URL: "http://localhost"}}); err == nil || !strings.Contains(err.Error(), "no message") {
		t.Fatalf("empty message: err=%v, want no-message error", err)
	}
}
