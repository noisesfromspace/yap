package turn

import (
	"encoding/json"
	"fmt"
	"strings"
	"sync"

	"boers.email/yap/agent/llm"
	"boers.email/yap/agent/render"
	"boers.email/yap/agent/safety"
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/wire"
)

// Only read-only, independent tools may share a model round. In particular,
// never speculate about whether two shell commands or edits commute.
var parallelTools = map[string]bool{
	"read": true, "search": true, "glob": true,
	"fetch": true, "websearch": true, "models": true,
}

const maxConcurrentTasks = 4

type taskResult struct{ result, ui string }
type backgroundTask struct {
	id, name string
	done     chan struct{}
	value    taskResult
}
type taskPool struct {
	mu    sync.Mutex
	next  int
	tasks map[string]*backgroundTask
}

func (p *taskPool) pending() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	ids := make([]string, 0, len(p.tasks))
	for i := 1; i <= p.next; i++ {
		id := fmt.Sprintf("task-%d", i)
		if p.tasks[id] != nil {
			ids = append(ids, id)
		}
	}
	return ids
}

func (p *taskPool) wait(ids []string) string {
	if len(ids) == 0 {
		ids = p.pending()
	}
	if len(ids) == 0 {
		return "No outstanding tasks."
	}
	var out strings.Builder
	seen := make(map[string]bool)
	for _, id := range ids {
		if seen[id] {
			continue
		}
		seen[id] = true
		p.mu.Lock()
		task := p.tasks[id]
		p.mu.Unlock()
		if task == nil {
			fmt.Fprintf(&out, "%s: unknown or already collected task\n", id)
			continue
		}
		<-task.done
		fmt.Fprintf(&out, "%s (%s):\n%s\n", id, task.name, task.value.result)
		p.mu.Lock()
		delete(p.tasks, id)
		p.mu.Unlock()
	}
	return strings.TrimSpace(out.String())
}

// staticGate runs a tool's deterministic guard rules before it executes. A
// matching rule pauses for approval; no rule means the call runs. It returns
// a non-empty denial string (an error the model sees) when approval is
// refused or unavailable.
func staticGate(call llm.ToolCall) string {
	if reason := tools.Match(call.Name, call.Input); reason != "" {
		approved, err := wire.RequestApproval(safety.Scrub(string(call.Input)), call.Name, reason)
		if err != nil {
			return "error: " + err.Error()
		}
		if !approved {
			return "error: " + call.Name + " rejected by user"
		}
	}
	return ""
}

func allowedTool(name string, allowed *[]string) bool {
	if allowed == nil {
		return true
	}
	for _, n := range *allowed {
		if n == name {
			return true
		}
	}
	return false
}

func runTool(tool *tools.Tool, call llm.ToolCall) taskResult {
	result, ui, err := tool.Run(call.Input)
	if err != nil {
		result, ui = "error: "+err.Error(), ""
	} else {
		result = render.FenceResult(call.Name, string(call.Input), result)
	}
	return taskResult{safety.Scrub(result), ui}
}

func (p *taskPool) call(call llm.ToolCall, allowed *[]string) taskResult {
	if !allowedTool(call.Name, allowed) {
		return taskResult{result: "error: unknown tool " + call.Name}
	}
	switch call.Name {
	case "wait_tasks":
		var args struct {
			IDs []string `json:"ids"`
		}
		if err := json.Unmarshal(call.Input, &args); err != nil {
			return taskResult{result: "error: " + err.Error()}
		}
		return taskResult{result: p.wait(args.IDs)}
	case "start_task":
		var args struct {
			Tool      string `json:"tool"`
			Arguments string `json:"arguments"`
		}
		if err := json.Unmarshal(call.Input, &args); err != nil {
			return taskResult{result: "error: " + err.Error()}
		}
		if args.Tool != "bash" && args.Tool != "fetch" && args.Tool != "websearch" {
			return taskResult{result: "error: background tool must be bash, fetch, or websearch"}
		}
		if !allowedTool(args.Tool, allowed) {
			return taskResult{result: "error: tool not allowed: " + args.Tool}
		}
		tool, ok := tools.Get(args.Tool)
		if !ok {
			return taskResult{result: "error: unknown tool " + args.Tool}
		}
		if trimmed := strings.TrimSpace(args.Arguments); trimmed == "" || trimmed[0] != '{' || !json.Valid([]byte(args.Arguments)) {
			return taskResult{result: "error: arguments must be a JSON object string"}
		}
		p.mu.Lock()
		if len(p.tasks) >= maxConcurrentTasks {
			p.mu.Unlock()
			return taskResult{result: "error: too many outstanding tasks; call wait_tasks first"}
		}
		p.mu.Unlock()
		inner := llm.ToolCall{ID: call.ID, Name: args.Tool, Input: json.RawMessage(args.Arguments)}
		if denial := staticGate(inner); denial != "" {
			return taskResult{result: denial}
		}
		p.mu.Lock()
		p.next++
		id := fmt.Sprintf("task-%d", p.next)
		task := &backgroundTask{id: id, name: args.Tool, done: make(chan struct{})}
		p.tasks[id] = task
		p.mu.Unlock()
		wire.EmitEvent(map[string]any{"type": "task_start", "id": id, "name": args.Tool})
		go func() {
			task.value = runTool(tool, inner)
			status := "completed"
			if strings.HasPrefix(task.value.result, "error:") {
				status = "failed"
			}
			// A turn cancel aborts the task (RunStreamed/fetch/curl/glob/search
			// all select on TurnContext), so record that in the audit log.
			if wire.TurnContext().Err() != nil {
				status = "cancelled"
			}
			wire.EmitEvent(map[string]any{"type": "task_end", "id": id, "name": args.Tool, "status": status, "result": task.value.result})
			close(task.done)
		}()
		return taskResult{result: fmt.Sprintf("Started %s (%s). Continue independent work; call wait_tasks before using its result.", id, args.Tool)}
	}
	tool, ok := tools.Get(call.Name)
	if !ok {
		return taskResult{result: "error: unknown tool " + call.Name}
	}
	if denial := staticGate(call); denial != "" {
		return taskResult{result: denial}
	}
	return runTool(tool, call)
}
