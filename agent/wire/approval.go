package wire

import (
	"fmt"
	"sync"
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
	Auto     bool   `json:"auto,omitempty"`
	TS       string `json:"ts,omitempty"`
}

var approvalSeq atomic.Uint64

// ApprovalDecision is transcript-only metadata, never part of a native tool
// result. TS records the decision, not when the tool eventually finishes.
type ApprovalDecision struct {
	Type    string `json:"type"`
	TS      string `json:"ts"`
	Text    string `json:"text"`
	ID      string `json:"id"`
	Tool    string `json:"tool"`
	Reason  string `json:"reason"`
	Outcome string `json:"outcome"`
}

var decisionMu sync.Mutex
var decisionCapture *[]ApprovalDecision

// CaptureApprovalDecisions scopes collection to one serial tool call, including
// approvals requested by MCP callback goroutines. Parallel built-in reads cannot
// request approval. Finish must be called before starting the next serial call.
func CaptureApprovalDecisions() (finish func() []ApprovalDecision) {
	decisionMu.Lock()
	var decisions []ApprovalDecision
	previous := decisionCapture
	decisionCapture = &decisions
	decisionMu.Unlock()
	return func() []ApprovalDecision {
		decisionMu.Lock()
		defer decisionMu.Unlock()
		decisionCapture = previous
		return decisions
	}
}

func recordApprovalDecision(id, tool, reason, outcome, ts string) {
	label := map[string]string{
		"approved": "Approved by you", "denied": "Denied by you",
		"auto-approved": "Auto-approved", "timeout": "Approval timed out",
	}[outcome]
	if ts == "" {
		ts = time.Now().UTC().Format(time.RFC3339Nano)
	}
	decision := ApprovalDecision{
		Type: "guard_decision", TS: ts,
		Text: label + " · " + tool, ID: id, Tool: tool, Reason: reason, Outcome: outcome,
	}
	decisionMu.Lock()
	defer decisionMu.Unlock()
	if decisionCapture != nil {
		*decisionCapture = append(*decisionCapture, decision)
	}
}

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
				outcome := "denied"
				if r.Approved {
					outcome = "approved"
					if r.Auto {
						outcome = "auto-approved"
					}
				}
				recordApprovalDecision(id, tool, reason, outcome, r.TS)
				return r.Approved, nil
			}
			// A reply for a stale request (shouldn't happen: one turn at a
			// time) is dropped.
		case <-TurnContext().Done():
			return false, fmt.Errorf("approval cancelled")
		case <-timer.C:
			recordApprovalDecision(id, tool, reason, "timeout", "")
			EmitEvent(map[string]any{"type": "approval_timeout", "id": id})
			return false, fmt.Errorf("approval timed out after %s", approvalTimeout)
		}
	}
}
