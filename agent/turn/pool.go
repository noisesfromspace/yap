package turn

import (
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
	"fetch": true, "models": true,
}

const maxConcurrentTasks = 4

type taskResult struct{ result, ui string }

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

func callTool(call llm.ToolCall, allowed *[]string) taskResult {
	if !allowedTool(call.Name, allowed) {
		return taskResult{result: "error: unknown tool " + call.Name}
	}
	tool, ok := tools.Get(call.Name)
	if !ok {
		if hint := lazyHint(call.Name); hint != "" {
			return taskResult{result: hint}
		}
		return taskResult{result: "error: unknown tool " + call.Name}
	}
	if denial := staticGate(call); denial != "" {
		return taskResult{result: denial}
	}
	return runTool(tool, call)
}
