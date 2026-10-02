package tools

import (
	"fmt"
	"sync/atomic"

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

type subagentArgs struct {
	Role string `json:"role" jsonschema:"description=name of a role from ~/.pi/agent/roles/*.md"`
	Task string `json:"task" jsonschema:"description=self-contained task for an isolated Yap session"`
}

func init() {
	Register("subagent", "Delegate a task to a role in an isolated, saved Yap Markdown session. Wait for its final answer; returns the child session path and result.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		utils.EmitEvent(map[string]any{"type": "subagent_request", "id": id, "role": a.Role, "task": a.Task})
		for {
			reply := <-SubagentReplies
			if reply.ID == id {
				return reply.Result, "", nil
			}
		}
	})
}
