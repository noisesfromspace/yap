package tools

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"boers.email/yap/agent/wire"
)

// Each outstanding delegation owns its reply channel. The serve stdin reader
// dispatches by ID, so late and out-of-order replies cannot reach another call.
var SubagentReplies = make(map[string]chan SubagentReply)
var subagentMu sync.Mutex

func DeliverSubagentReply(reply SubagentReply) {
	subagentMu.Lock()
	ch := SubagentReplies[reply.ID]
	subagentMu.Unlock()
	if ch != nil {
		select {
		case ch <- reply:
		default:
		}
	}
}

type SubagentReply struct {
	ID     string `json:"id"`
	Path   string `json:"path,omitempty"`
	Result string `json:"result,omitempty"`
}

var subagentID atomic.Uint64
var subagentWait = 30 * time.Minute

type subagentArgs struct {
	Agent string   `json:"agent" jsonschema:"description=name of an agent definition from the ## Agents list in your system prompt (definition files in ~/.config/yap/agents/*.md)"`
	Model string   `json:"model,omitempty" jsonschema_description:"provider/model combo the child runs on, overriding the agent definition's model (use the models tool to list combos); omitted for the definition's model, or the parent's combo when it names none"`
	Task  string   `json:"task" jsonschema:"description=task for the subagent"`
	Tools []string `json:"tools" jsonschema:"description=tools the child may use; choose for this task (e.g. read/search/glob for research; add bash/edit/write only when needed); cannot include subagent"`
}

func init() {
	Register("subagent", "Delegate a task to a saved agent definition. The calling model must choose a nonempty tools list for this task; definitions cannot grant tools. Choose only names the child needs (read/search/glob for research; add bash/edit/write when needed). Delegation cannot grant the subagent tool. The child still uses normal approvals and sandboxing. Returns the child's answer and session path; waits up to 30 minutes and, on timeout or cancellation, still reports the child session path so its work stays recoverable.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		ch := make(chan SubagentReply, 2)
		subagentMu.Lock()
		SubagentReplies[id] = ch
		subagentMu.Unlock()
		defer func() {
			subagentMu.Lock()
			delete(SubagentReplies, id)
			subagentMu.Unlock()
		}()
		wire.EmitSubagentRequest(id, a.Agent, a.Model, a.Task, a.Tools)
		timer := time.NewTimer(subagentWait)
		defer timer.Stop()
		path := ""
		link := func() string {
			if path == "" {
				return " (child session was not confirmed)"
			}
			return " Session: [" + path + "](" + path + ")"
		}
		for {
			select {
			case reply := <-ch:
				if reply.Path != "" {
					path = reply.Path
				}
				if reply.Result != "" {
					return reply.Result, "", nil
				}
			case <-wire.TurnContext().Done():
				return "", "", fmt.Errorf("subagent cancelled;%s", link())
			case <-timer.C:
				wire.EmitEvent(map[string]any{"type": "subagent_timeout", "id": id})
				return "", "", fmt.Errorf("subagent timed out after %s;%s", subagentWait, link())
			}
		}
	})
	// No static gate: delegation is inert — the child's own tool calls
	// (the bash rule list above all) carry the gates.
}
