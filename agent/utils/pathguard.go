package utils

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"
)

// secretPaths are directories read/write/edit must never touch. They are
// matched against BOTH the literal absolute path and the symlink-resolved
// path, so neither a direct path nor a link into them can pass (e.g.
// /run/agenix is itself a symlink to /run/agenix.d/N). The age identity
// (~/.ssh/id_ed25519_age) lives in ~/.ssh, so one entry covers both SSH
// and agenix keys. Decrypted agenix secrets are served from /run/agenix;
// their encrypted .age files in a flake are safe to read and are NOT
// blocked — age encryption is the point.
var secretPaths = func() []string {
	var paths []string
	if h, err := os.UserHomeDir(); err == nil && h != "" {
		paths = append(paths,
			filepath.Join(h, ".ssh"),
			filepath.Join(h, ".gnupg"),
			filepath.Join(h, ".aws"),
			filepath.Join(h, ".config", "sops"),
		)
	}
	return append(paths, "/etc/ssh", "/run/agenix", "/etc/agenix")
}()

// resolvePath returns the absolute, cleaned path with symlinks resolved in
// the longest existing prefix. The non-existent tail (a file being created)
// is re-appended, so a symlink in an existing ancestor still resolves. It
// falls back to the cleaned absolute path when nothing resolves.
func resolvePath(p string) (string, error) {
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
// home directory, so `~/.local/share/yap/scratch/x.py` works in every path field. Only
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

func isSecretPath(abs string) bool {
	for _, s := range secretPaths {
		if abs == s || strings.HasPrefix(abs, s+string(filepath.Separator)) {
			return true
		}
	}
	return false
}

func isWithin(root, p string) bool {
	return p == root || strings.HasPrefix(p, root+string(filepath.Separator))
}

// GuardReadPath blocks reads of secret paths. Both the literal path and the
// symlink-resolved path are checked. A non-existent path is left for the
// caller's normal not-found error.
func GuardReadPath(p string) error {
	abs, err := filepath.Abs(p)
	if err != nil {
		return err
	}
	if isSecretPath(filepath.Clean(abs)) {
		return fmt.Errorf("refusing to read %s: secret path", p)
	}
	if resolved, err := resolvePath(p); err == nil && isSecretPath(resolved) {
		return fmt.Errorf("refusing to read %s: secret path", p)
	}
	return nil
}

// GuardWritePath blocks writes to secret paths and returns an advisory note
// for writes outside the project root (the backend process cwd). The note
// is surfaced to the model, not an error: yap deliberately runs bash
// unsandboxed, so this is defense against accidental path mistakes, not a
// security boundary.
func GuardWritePath(p string) (note string, err error) {
	abs, err := filepath.Abs(p)
	if err != nil {
		return "", err
	}
	abs = filepath.Clean(abs)
	if isSecretPath(abs) {
		return "", fmt.Errorf("refusing to write %s: secret path", p)
	}
	resolved, err := resolvePath(p)
	if err != nil {
		return "", err
	}
	if isSecretPath(resolved) {
		return "", fmt.Errorf("refusing to write %s: secret path", p)
	}
	if root, err := os.Getwd(); err == nil && root != "" && !isWithin(root, resolved) {
		note = fmt.Sprintf("note: writing outside project root %s: %s", root, resolved)
	}
	return note, nil
}
