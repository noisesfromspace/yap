package tools

// The loop owns task state and dispatch. These registrations supply validated
// schemas to the model; Run must never execute a task outside that loop.
type startTaskArgs struct {
	Tool      string `json:"tool" jsonschema_description:"tool to run in the background: bash, fetch, or websearch"`
	Arguments string `json:"arguments" jsonschema_description:"arguments for the selected tool, encoded as a JSON object string (e.g. {\"command\":\"ls\"})"`
}

type waitTasksArgs struct {
	IDs []string `json:"ids" jsonschema:"description=task IDs returned by start_task; omit to wait for all outstanding tasks"`
}

func init() {
	Register("start_task", "Start a long-running bash, fetch, or websearch call in the background and return a task ID immediately. Use it when you can overlap slow work: launch the slow call, do other useful work, then call wait_tasks once to collect the result before relying on it. For example, start a test run or build, then read files or research meanwhile. The inner call's guard rules and approval still apply before launch. Tasks are scoped to this turn and cannot survive a final answer or stop. Do not start commands that conflict with ongoing work.", func(*startTaskArgs) (string, string, error) {
		return "error: start_task requires the agent loop", "", nil
	})
	Register("wait_tasks", "Wait for background tasks to finish and return their results. Omit ids to wait for all outstanding tasks; do not poll repeatedly. Call once before relying on a background result or reporting success; any remaining tasks are waited for automatically before a final answer.", func(*waitTasksArgs) (string, string, error) {
		return "error: wait_tasks requires the agent loop", "", nil
	})
}
