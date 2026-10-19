package utils

import (
	"fmt"
	"sync/atomic"
	"time"
)

// ApprovalReplies is installed by the serve process (like the subagent reply
// channel): the frontend writes {"type":"approval_result","id":...,"approved":...}
// lines to stdin and serve forwards them here. Tools call RequestApproval and
// block until a matching reply arrives or the timeout denies. Nil means no
// human can answer (yap send, unit tests), in which case the request is
// denied — the safe default.
var ApprovalReplies chan ApprovalReply

// ApprovalReply is the frontend's answer to an approval request.
type ApprovalReply struct {
	ID       string `json:"id"`
	Approved bool   `json:"approved"`
}

var approvalSeq atomic.Uint64

// approvalTimeout is how long a turn waits for the human before denying.
var approvalTimeout = 5 * time.Minute

// RequestApproval pauses the turn and asks the user to approve running
// `command` (shown verbatim; the Lua side truncates for display). The tool
// and reason are recorded with the request so audit history explains why
// the dialog appeared — `reason` is the static guard rule that matched
// (or the tool's own always-approval label). It returns (true, nil) when
// approved, (false, nil) when denied, and an error when there is no serve
// process to ask or the user never answers. Denial and timeout are surfaced
// to the model as a tool error.
func RequestApproval(command, tool, reason string) (bool, error) {
	if ApprovalReplies == nil {
		return false, fmt.Errorf("approval requires yap serve")
	}
	id := fmt.Sprintf("approval-%d", approvalSeq.Add(1))
	EmitApprovalRequest(id, command, tool, reason)
	timer := time.NewTimer(approvalTimeout)
	defer timer.Stop()
	for {
		select {
		case r := <-ApprovalReplies:
			if r.ID == id {
				return r.Approved, nil
			}
			// A reply for a stale request (shouldn't happen: one turn at a
			// time) is dropped.
		case <-timer.C:
			EmitEvent(map[string]any{"type": "approval_timeout", "id": id})
			return false, fmt.Errorf("approval timed out after %s", approvalTimeout)
		}
	}
}
