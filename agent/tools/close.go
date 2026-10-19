package tools

import "boers.email/yap/agent/utils"

// close_session is a frontend side effect (like quickfix): the tool itself
// performs no Go-side action beyond emitting the close_session frame; the
// Neovim side sees it and closes the session buffer once the turn has fully
// completed and the session file has been saved, so the request survives as
// a persisted tool region but never replays on reopen.
type closeArgs struct{}

func init() {
	Register("close_session",
		"Ask Neovim to close this yap session buffer once the current turn has finished streaming and the session file has been saved. Use it only when the user has asked to end/close the session (e.g. \"close the session when done\").",
		func(a *closeArgs) (string, string, error) {
			utils.EmitCloseSession()
			return "session close requested; the buffer will be closed once this turn completes", "", nil
		})
}
