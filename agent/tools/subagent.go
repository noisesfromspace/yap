package tools

import (
	"fmt"
	"sync/atomic"
	"time"

	"boers.email/yap/agent/wire"
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
	Agent string   `json:"agent" jsonschema:"description=name of an agent definition from the ## Agents list in your system prompt (definition files in ~/.config/yap/agents/*.md)"`
	Model string   `json:"model,omitempty" jsonschema_description:"provider/model combo the child runs on, overriding the agent definition's model (use the models tool to list combos); omitted for the definition's model, or the parent's combo when it names none"`
	Task  string   `json:"task" jsonschema:"description=task for the subagent"`
	Tools []string `json:"tools" jsonschema:"description=tools the child may use; choose for this task (e.g. read/search/glob for research; add bash/edit/write only when needed); cannot include subagent"`
}

func init() {
	Register("subagent", "Delegate a task to a saved agent definition. The calling model must choose a nonempty tools list for this task; definitions cannot grant tools. Choose only names the child needs (read/search/glob for research; add bash/edit/write when needed). Delegation cannot grant the subagent tool. The child still uses normal approvals and sandboxing. Returns the child's answer and session path.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		wire.EmitSubagentRequest(id, a.Agent, a.Model, a.Task, a.Tools)
		timer := time.NewTimer(subagentWait)
		defer timer.Stop()
		for {
			select {
			case reply := <-SubagentReplies:
				if reply.ID == id {
					return reply.Result, "", nil
				}
			case <-wire.TurnContext().Done():
				return "", "", fmt.Errorf("subagent cancelled")
			case <-timer.C:
				wire.EmitEvent(map[string]any{"type": "subagent_timeout", "id": id})
				return "", "", fmt.Errorf("subagent timed out after %s", subagentWait)
			}
		}
	})
	// No static gate: delegation is inert — the child's own tool calls
	// (the bash rule list above all) carry the gates.
}
