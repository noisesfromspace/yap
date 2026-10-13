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
	Agent   string `json:"agent,omitempty" jsonschema:"description=name of an agent definition from the ## Agents list in your system prompt (definition files in ~/.config/yap/agents/*.md); omit when continuing a session"`
	Model   string `json:"model,omitempty" jsonschema_description:"provider/model combo the child runs on, overriding the agent definition's model (use the models tool to list combos); omitted for the definition's model, or the parent's combo when it names none. Ignored when continuing a session"`
	Task    string `json:"task" jsonschema:"description=task or follow-up question for the subagent"`
	Session string `json:"session,omitempty" jsonschema:"description=existing child session path returned by a previous subagent call; omit to start a new session"`
}

func init() {
	Register("subagent", "Delegate a self-contained subtask to a saved agent definition and wait for its answer. Use when a task is large or independent enough to benefit from its own context or a different (often cheaper) model; see the ## Agents list for the available agents and what each is for. Returns the child's answer and session path. Pass `session` to continue a previous child instead of starting a new one.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		utils.EmitEvent(map[string]any{"type": "subagent_request", "id": id, "agent": a.Agent, "model": a.Model, "task": a.Task, "session": a.Session})
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
