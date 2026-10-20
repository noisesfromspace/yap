package utils

import (
	"os"
	"path/filepath"
	"strings"
)

// Path resolution and environment roots shared by the tools. Secret paths
// are deliberately NOT handled here: they belong to the secrets domain
// (secrets.go — IsSecretPath, SecretPathRule), which reuses ResolvePath and
// ExpandHome below as its mechanics.

// ResolvePath returns the absolute, cleaned path with symlinks resolved in
// the longest existing prefix. The non-existent tail (a file being created)
// is re-appended, so a symlink in an existing ancestor still resolves. It
// falls back to the cleaned absolute path when nothing resolves.
func ResolvePath(p string) (string, error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	abs = filepath.Clean(abs)

	prefix, tail := abs, []string(nil)
	for {
		resolved, err := filepath.EvalSymlinks(prefix)
		if err == nil {
			if len(tail) == 0 {
				return resolved, nil
			}
			return filepath.Join(append([]string{resolved}, tail...)...), nil
		}
		parent := filepath.Dir(prefix)
		if parent == prefix { // reached the root; nothing resolves
			return abs, nil
		}
		tail = append([]string{filepath.Base(prefix)}, tail...)
		prefix = parent
	}
}

// ExpandHome resolves a leading ~ or ~/ in a user-supplied path to the
// home directory, so `~/x.py` works in every path field. Only
// the bare ~ form is handled (tools never need other-user home lookup);
// anything else — including `~user/` — is returned unchanged. On a home-dir
// lookup failure the input is returned untouched and the tool's normal
// error path applies.
func ExpandHome(p string) string {
	h, err := os.UserHomeDir()
	if err != nil {
		return p
	}
	if p == "~" {
		return h
	}
	if strings.HasPrefix(p, "~/") {
		return filepath.Join(h, p[2:])
	}
	return p
}

// ToolPath resolves a tool-supplied filesystem path the way a subprocess tool
// does: expands a leading ~ and resolves a relative path against the frontend
// cwd (the project), falling back to the process cwd when the frontend sent
// none (one-shot `yap send`). bash already gets this via cmd.Dir = frontend
// cwd; this is the same resolution for the in-process mutating tools
// (write/edit), so their "relative or absolute" schema field, the bash
// sandbox, and the writable-allowlist guard (safety.IsWritablePath) all agree
// on where a relative path lands after a :cd.
func ToolPath(p string) string {
	p = ExpandHome(p)
	if p == "" || filepath.IsAbs(p) {
		return p
	}
	if cwd := FrontendCwd(); cwd != "" {
		return filepath.Join(cwd, p)
	}
	if cwd, err := os.Getwd(); err == nil {
		return filepath.Join(cwd, p)
	}
	return p
}

// frontendCwd is the frontend's working directory for the turn in progress.
// The backend process's own cwd is fixed when the buffer spawns it, so a
// `:cd` in Neovim is invisible here: without this the documented default for
// bash ("the Neovim cwd") would be stale.
var frontendCwd string

// SetFrontendCwd records the cwd the frontend sent with this turn.
func SetFrontendCwd(dir string) { frontendCwd = dir }

// FrontendCwd returns the cwd reported with this turn, or "" when the
// frontend sent none (a one-shot `yap send`). Callers then keep the process
// cwd (cmd.Dir unset), which is where they already are.
func FrontendCwd() string { return frontendCwd }

// assetsBase is the directory transient tool files are created in: the
// frontend's per-session assets dir when it sent one, else the system temp dir.
var assetsBase string

// SetAssetsBase records the per-session assets dir the frontend sent this turn.
func SetAssetsBase(dir string) { assetsBase = dir }

// AssetsBase returns the directory for transient tool files (live-tail logs,
// inline scripts, header files, SSH sockets), creating it when the frontend
// supplied one. Falls back to the system temp dir (which honors $TMPDIR) so
// a one-shot `yap send` behaves as before.
func AssetsBase() string {
	if assetsBase != "" {
		if err := os.MkdirAll(assetsBase, 0o700); err == nil {
			return assetsBase
		}
	}
	return os.TempDir()
}
