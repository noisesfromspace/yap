package utils

import "os"

// JailTool returns the path to a sandbox wrapper for the given tool, or
// fallback when none is configured. The jail is strictly opt-in: the
// packaged agent (flake.nix) sets YAP_JAIL_* to a bubblewrap wrapper and the
// tool execs it; any other build (plain `go build`, the dev shell) leaves the
// variable unset and gets the bare tool, exactly as before the jail existed.
// A set-but-broken path (e.g. a stale store path after a GC) also degrades to
// the bare tool rather than erroring, so the jail can never break a tool.
func JailTool(envVar, fallback string) string {
	if p := os.Getenv(envVar); p != "" && isExecutable(p) {
		return p
	}
	return fallback
}

func isExecutable(p string) bool {
	fi, err := os.Stat(p)
	return err == nil && !fi.IsDir() && fi.Mode()&0o111 != 0
}
