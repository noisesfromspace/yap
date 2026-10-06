package tools

import (
	"fmt"
	"sync/atomic"
	"time"

	"boers.email/yap/agent/utils"
)

// SubagentReplies is installed by serve. Each serve process handles one turn
// at a time; stdin is still read while a subagent tool is waiting.
var SubagentReplies chan SubagentReply

type SubagentReply struct {
	ID     string `json:"id"`
	Result string `json:"result"`
}

var subagentID atomic.Uint64
var subagentWait = 10 * time.Minute

type subagentArgs struct {
	Role    string `json:"role,omitempty" jsonschema:"description=name of a role from ~/.yap/roles/*.md (or configured roles_dir); omit when continuing a session"`
	Task    string `json:"task" jsonschema:"description=task or follow-up question for the subagent"`
	Session string `json:"session,omitempty" jsonschema:"description=existing child session path returned by a previous subagent call; omit to start a new session"`
}

func init() {
	Register("subagent", "Delegate to a role in an isolated, saved Yap Markdown session, or continue a previous child using session. Wait for its answer; returns the session path and result.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		utils.EmitEvent(map[string]any{"type": "subagent_request", "id": id, "role": a.Role, "task": a.Task, "session": a.Session})
		timer := time.NewTimer(subagentWait)
		defer timer.Stop()
		for {
			select {
			case reply := <-SubagentReplies:
				if reply.ID == id {
					return reply.Result, "", nil
				}
			case <-timer.C:
				utils.EmitEvent(map[string]any{"type": "subagent_timeout", "id": id})
				return "", "", fmt.Errorf("subagent timed out after %s", subagentWait)
			}
		}
	})
	// A subagent runs a full turn with its own tools; gate the delegation.
	Gate("subagent", utils.TierAskJev, nil)
}
