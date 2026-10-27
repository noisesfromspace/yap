package wire

import (
	"sync"
	"syscall"
)

// ─── Running process groups ──────────────────────────────────────────────────

var (
	runningMu sync.Mutex
	running   = map[int]bool{}
)

// Track registers a process group id so KillAll can signal it.
func Track(pgid int) { runningMu.Lock(); running[pgid] = true; runningMu.Unlock() }

// Untrack removes a finished process group id.
func Untrack(pgid int) { runningMu.Lock(); delete(running, pgid); runningMu.Unlock() }

// KillAll SIGKILLs every tracked tool process group; used on SIGTERM/SIGINT
// so a killed backend takes its in-flight commands down with it. A user
// stop() no longer reaches this path — it cancels the turn via the protocol
// while the process (and the tool state it owns) stay alive.
func KillAll() {
	runningMu.Lock()
	defer runningMu.Unlock()
	for pgid := range running {
		_ = syscall.Kill(-pgid, syscall.SIGKILL)
	}
}
