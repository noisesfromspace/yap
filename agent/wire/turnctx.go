package wire

import "context"

// The currently-running turn's context. serve derives it per turn and hands
// it to runTurn, which installs it here (and clears it on return). Tools
// consult it to abort promptly when the frontend cancels a turn — instead of
// the old kill-the-process model, which tore down SSH control masters and
// every other tool state on stop(). Package-level mutable state, matching
// ApprovalReplies/SubagentReplies: the tool interface (Run(input) -> result)
// carries no context, so this is the one place a tool can reach cancellation.
var turnCtx context.Context = context.Background()

// SetTurnContext installs the running turn's context (nil means Background).
func SetTurnContext(ctx context.Context) {
	if ctx == nil {
		ctx = context.Background()
	}
	turnCtx = ctx
}

// TurnContext returns the running turn's context, for tools to select on.
func TurnContext() context.Context {
	return turnCtx
}
