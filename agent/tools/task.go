package tools

import "encoding/json"

// The loop owns task state and dispatch. These registrations supply validated
// schemas to the model; Run must never execute a task outside that loop.
type startTaskArgs struct {
	Tool      string          `json:"tool" jsonschema:"description=tool to run in the background: bash, fetch, or websearch"`
	Arguments json.RawMessage `json:"arguments" jsonschema:"description=arguments for the selected tool, in its normal JSON object form"`
}

type waitTasksArgs struct {
	IDs []string `json:"ids" jsonschema:"description=task IDs returned by start_task; omit to wait for all outstanding tasks"`
}

func init() {
	Register("start_task", "Start a long-running bash, fetch, or websearch call and return a task ID immediately. Use when there is independent work to do while it runs; call wait_tasks before relying on its result. The normal safety gate and approval still apply before launch. Tasks are scoped to this turn and cannot survive a final answer or stop. Do not use for edits or commands that conflict with ongoing work.", func(*startTaskArgs) (string, string, error) {
		return "error: start_task requires the agent loop", "", nil
	})
	Register("wait_tasks", "Wait efficiently for background tasks to finish and return their results. Omit ids to wait for all; do not repeatedly poll. Use before reporting success or relying on a background result. Any remaining tasks are automatically waited for before a final answer.", func(*waitTasksArgs) (string, string, error) {
		return "error: wait_tasks requires the agent loop", "", nil
	})
}
