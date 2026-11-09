package tools

import (
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"boers.email/yap/agent/wire"
)

// Each outstanding delegation owns its reply channel and its progress
// channel. The serve stdin reader dispatches by ID, so late and out-of-order
// replies cannot reach another call, and one delegation's liveness signals
// never leak into another.
var SubagentReplies = make(map[string]chan SubagentReply)
var SubagentProgresses = make(map[string]chan SubagentProgress)
var subagentMu sync.Mutex

// SubagentStop is installed by serve as a buffered token channel. A graceful
// turn cancel sends one token here, so a delegation waiting on a child aborts
// its wait immediately instead of blocking until the child's result frame
// arrives. Reading a nil channel blocks forever, which is correct when no
// serve process is installed (yap send, unit tests).
var SubagentStop chan struct{}

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

// DeliverSubagentProgress routes a liveness signal to the delegation waiting
// on that child. The frontend sends these as the child works, so the tool can
// reset its inactivity deadline — or suspend it while the child is parked on a
// human approval. Dropping on a full channel is fine: progress is advisory,
// and the next signal refreshes the clock.
func DeliverSubagentProgress(p SubagentProgress) {
	subagentMu.Lock()
	ch := SubagentProgresses[p.ID]
	subagentMu.Unlock()
	if ch != nil {
		select {
		case ch <- p:
		default:
		}
	}
}

type SubagentReply struct {
	ID     string `json:"id"`
	Path   string `json:"path,omitempty"`
	Result string `json:"result,omitempty"`
}

// SubagentProgress is a liveness signal from the frontend. Status is one of
// "tool" (a child tool started), "output" (streamed bytes arrived), "text"
// (the child model is generating) or "approval" (the child is parked on a
// human approval). The tool uses it only to keep its inactivity deadline
// honest; the bytes and labels stay on the frontend and never reach the
// parent model's context.
type SubagentProgress struct {
	ID     string `json:"id"`
	Status string `json:"status"`
}

var subagentID atomic.Uint64
var subagentWait = 30 * time.Minute

// subagentInactivityWait is how long a delegation waits for any sign of child
// progress before giving up. Reset on each progress signal, suspended while
// the child waits for a human approval. A var so tests can shorten it.
var subagentInactivityWait = 3 * time.Minute

type subagentArgs struct {
	Agent string   `json:"agent" jsonschema:"description=name of an agent definition from the ## Agents list in your system prompt (definition files in ~/.config/yap/agents/*.md)"`
	Model string   `json:"model,omitempty" jsonschema:"description=provider/model combo the child runs on, overriding the agent definition's model (use the models tool to list combos); omitted for the definition's model, or the parent's combo when it names none"`
	Task  string   `json:"task" jsonschema:"description=task for the subagent"`
	Tools []string `json:"tools" jsonschema:"description=tools the child may use; choose for this task (e.g. read/search/glob for research; add bash/edit/write only when needed); cannot include subagent"`
}

func init() {
	Register("subagent", "Delegate a task to a saved agent definition. The calling model must choose a nonempty tools list for this task; definitions cannot grant tools. Choose only names the child needs (read/search/glob for research; add bash/edit/write when needed). Delegation cannot grant the subagent tool. The child still uses normal approvals and sandboxing. Returns the child's answer and session path; waits up to 30 minutes, but gives up earlier if the child stops making progress, and on timeout or cancellation still reports the child session path so its work stays recoverable.", func(a *subagentArgs) (string, string, error) {
		if SubagentReplies == nil {
			return "", "", fmt.Errorf("subagent requires yap serve")
		}
		id := fmt.Sprintf("%d", subagentID.Add(1))
		ch := make(chan SubagentReply, 2)
		pch := make(chan SubagentProgress, 16)
		subagentMu.Lock()
		SubagentReplies[id] = ch
		SubagentProgresses[id] = pch
		subagentMu.Unlock()
		defer func() {
			subagentMu.Lock()
			delete(SubagentReplies, id)
			delete(SubagentProgresses, id)
			subagentMu.Unlock()
		}()
		wire.EmitSubagentRequest(id, a.Agent, a.Model, a.Task, a.Tools)
		// Two deadlines: a hard cap on the whole delegation, and an
		// inactivity deadline that resets on every sign of child progress.
		hard := time.NewTimer(subagentWait)
		defer hard.Stop()
		inactivity := time.NewTimer(subagentInactivityWait)
		defer inactivity.Stop()
		resetInactivity := func() {
			if !inactivity.Stop() {
				select {
				case <-inactivity.C:
				default:
				}
			}
			inactivity.Reset(subagentInactivityWait)
		}
		suspended := false
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
					resetInactivity() // the child was spawned: that is progress
				}
				if reply.Result != "" {
					return reply.Result, "", nil
				}
			case p := <-pch:
				if p.Status == "approval" {
					// Waiting on a human is not stalling: suspend the clock.
					if !suspended {
						if !inactivity.Stop() {
							select {
							case <-inactivity.C:
							default:
							}
						}
						suspended = true
					}
				} else {
					if suspended {
						suspended = false
					}
					resetInactivity()
				}
			case <-wire.TurnContext().Done():
				// Hard cancellation (backend shutdown).
				return "", "", fmt.Errorf("subagent cancelled;%s", link())
			case <-SubagentStop:
				// Graceful stop: the frontend is stopping the child, so stop
				// waiting and let the turn end as cancelled.
				return "", "", fmt.Errorf("subagent cancelled;%s", link())
			case <-inactivity.C:
				wire.EmitEvent(map[string]any{"type": "subagent_timeout", "id": id, "reason": "inactivity"})
				return "", "", fmt.Errorf("subagent timed out after %s without progress;%s", subagentInactivityWait, link())
			case <-hard.C:
				wire.EmitEvent(map[string]any{"type": "subagent_timeout", "id": id})
				return "", "", fmt.Errorf("subagent timed out after %s;%s", subagentWait, link())
			}
		}
	})
	// No static gate: delegation is inert — the child's own tool calls
	// (the bash rule list above all) carry the gates.
}
