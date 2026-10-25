package safety

import (
	"os"
	"path/filepath"
	"strings"

	"boers.email/yap/agent/utils"
)

// The secrets domain is the one responsible system for "secret material must
// not reach the transcript". One list of secret locations drives every
// surface:
//
//  1. secret paths — read/write/edit/search declare a SecretPathRule that
//     pauses for a Run/Deny before the tool touches a path under these
//     directories (IsSecretPath is the predicate). Approving is deliberate,
//     never the silent default.
//  2. secret-reveal commands — bash appends SecretRevealRules: commands
//     whose output IS secret material (decryption, private-key
//     generation/export, reading a secret file). bash has no path argument to
//     inspect, so these judge the parsed command line and pause for Run/Deny.
//  3. redaction — scrub.go redacts any secret that still reaches a result
//     (PEM keys, AGE-SECRET-KEY-…, bearer tokens, …), defense in depth
//     behind surfaces 1 and 2.
//
// Adding a secret location here updates the path guard, sandbox shadows and
// bash's reader-command guard together.

// secretLocations is the single source of secret paths. Home-relative entries
// expand against os.UserHomeDir for file checks and accept the usual shell
// spellings in bash commands.
var secretLocations = []string{
	"~/.ssh", "~/.gnupg", "~/.aws", "~/.config/sops",
	"/etc/ssh", "/run/agenix", "/run/agenix.d", "/etc/agenix",
}

// secretPaths are the secret directories read/write/edit/search must ask
// about before touching. They are matched against BOTH the literal absolute
// path and the symlink-resolved path, so neither a direct path nor a link into them can pass (e.g.
// /run/agenix is itself a symlink to /run/agenix.d/N). The age identity
// (~/.ssh/id_ed25519_age) lives in ~/.ssh, so one entry covers both SSH
// and agenix keys. Decrypted agenix secrets are served from /run/agenix;
// their encrypted .age files in a flake are safe to read and are NOT
// blocked — age encryption is the point.
//
// `/run/agenix` is itself a symlink to `/run/agenix.d/<n>`, and the
// resolved path does not sit under it, so both directories are listed (see
// secretLocations) or a read of the resolved path (or of /run/agenix.d itself)
// walks straight past the guard.
var secretPaths = buildSecretPaths()

func buildSecretPaths() []string {
	home, _ := os.UserHomeDir()
	var paths []string
	for _, p := range secretLocations {
		if strings.HasPrefix(p, "~/") {
			if home == "" {
				continue
			}
			p = filepath.Join(home, strings.TrimPrefix(p, "~/"))
		}
		paths = append(paths, p)
	}
	return paths
}

// SecretPaths returns the secret directories read/write/edit/search must ask
// about before touching — the same list IsSecretPath matches. The sandbox
// (sandbox.go) shadows these directories with empty mounts so bash cannot
// read them. The returned slice is a copy, so a caller cannot mutate the
// process-wide policy out from under the path checks and shadow mounts.
func SecretPaths() []string {
	out := make([]string, len(secretPaths))
	copy(out, secretPaths)
	return out
}

// pathIsUnder reports whether path equals dir or sits directly under it.
// dir is cleaned; empty and root directories never match. Shared by
// isSecretPath and sandbox.under so the two containment checks cannot drift.
func pathIsUnder(path, dir string) bool {
	sep := string(filepath.Separator)
	dir = filepath.Clean(dir)
	if dir == "" || dir == sep {
		return false
	}
	return path == dir || strings.HasPrefix(path, dir+sep)
}

func isSecretPath(abs string) bool {
	for _, s := range secretPaths {
		if pathIsUnder(abs, s) {
			return true
		}
	}
	return false
}

// IsSecretPath reports whether path is, or resolves into, a secret path. It
// is the single predicate behind read/write/edit/search's secret-path rules.
func IsSecretPath(p string) bool {
	p = utils.ExpandHome(p)
	abs, err := filepath.Abs(p)
	if err != nil {
		return false
	}
	if isSecretPath(filepath.Clean(abs)) {
		return true
	}
	if resolved, err := utils.ResolvePath(p); err == nil && isSecretPath(resolved) {
		return true
	}
	return false
}

// SecretPathRule builds a guard rule that pauses a call whose inspected path
// is, or resolves into, a secret path. It is the approval counterpart to
// Scrub: the gate asks before a tool touches a secret, and Scrub redacts any
// secret that still reaches a result. read/write/edit/search declare one in
// their init() with a tool-specific reason.
func SecretPathRule(name string) Rule {
	return Rule{Name: name, Match: func(p string) bool {
		return strings.TrimSpace(p) != "" && IsSecretPath(p)
	}}
}

// ─── Secret-reveal commands (bash approval rules) ───────────────────────────

// The bash half of the same policy: a command whose *output* is secret
// material. Worth keeping next to the sandbox's read shadow, because a command
// that matched any guard rule runs unsandboxed (the approval is the blessing)
// and a one-shot `yap send` has no sandbox at all — the shadow mount is the
// primary barrier, these rules are the backstop.
//
// They judge the parsed command line (shell.go): a reader is recognized by its
// command word, and a secret location by comparing the argument it names with
// IsSecretPath. So `echo ~/.ssh` is not a read, and `grep -r 'key' "$HOME/.ssh"`
// is one whatever quoting or spelling the path uses.

// secretReaders are the commands whose job is to print file contents, so
// naming a secret path in their arguments makes the output secret material.
var secretReaders = map[string]bool{
	"cat": true, "less": true, "more": true, "head": true, "tail": true,
	"bat": true, "batcat": true, "grep": true, "rg": true, "sed": true,
	"awk": true, "strings": true, "xxd": true, "od": true, "hexdump": true,
	"jq": true, "yq": true,
}

// secretRevealRules are the bash rules for commands whose output is secret
// material: decryption, private-key generation or export, and reading a file
// under a secret directory.
var secretRevealRules = []Rule{
	ShellAny("decrypts secret material", decryptsSecret),
	ShellAny("reveals a secret key", revealsSecretKey),
	ShellAny("reads a secret file", readsSecretFile),
}

// SecretRevealRules returns the bash guard rules for commands whose output is
// secret material. tools/bash.go appends these to its rule list; they surface
// in `yap guard` and the guard board like every other rule.
func SecretRevealRules() []Rule {
	return secretRevealRules
}

// decryptsSecret reports whether the command decrypts to stdout: age/gpg -d,
// a sops decrypt or exec-* run, openssl enc -d.
func decryptsSecret(c ShellCmd) bool {
	switch c.Name {
	case "age", "gpg", "gpg2":
		return c.Has("-d", "--decrypt")
	case "sops":
		return c.Has("-d", "decrypt", "exec-env", "exec-file")
	case "openssl":
		return c.Has("enc") && c.Has("-d", "--decrypt", "-decrypt")
	}
	return false
}

// revealsSecretKey reports whether the command prints private key material.
// age-keygen -y derives public recipients from an identity and is the one safe
// form.
func revealsSecretKey(c ShellCmd) bool {
	switch c.Name {
	case "age-keygen":
		return !c.Has("-y")
	case "gpg", "gpg2":
		return c.Has("--export-secret-keys", "--export-secret-subkeys")
	case "openssl":
		return c.Has("rsa", "ec", "dsa", "pkey", "genrsa", "genpkey", "pkcs8")
	}
	return false
}

// readsSecretFile reports whether a content-printing command names a path
// under a secret directory.
func readsSecretFile(c ShellCmd) bool {
	if !secretReaders[c.Name] {
		return false
	}
	for _, a := range c.Args {
		if IsSecretPath(a) {
			return true
		}
	}
	return false
}
