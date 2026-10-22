package safety

import (
	"os"
	"path/filepath"
	"regexp"
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
//     generation/export, reading a secret file). bash has no path to
//     inspect, only the command text, so these also pause for Run/Deny.
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

// decryptRE matches commands whose output is the decrypted plaintext — the
// secret itself. Each tool's decrypt flag is matched as a token: bare words
// use \b boundaries, dash-led flags match their literal dashes.
const decryptRE = `(?i)\bage\b[ \t]+(?:--decrypt|-d)\b|\bgpg(?:2)?\b[^\n;&|]*(?:--decrypt|-d)\b|\bsops\b[^\n;&|]*(?:\bdecrypt\b|\bexec-env\b|\bexec-file\b|-d\b)|\bopenssl\b[^\n;&|]*\benc\b[^\n;&|]*(?:-d\b|--decrypt\b|-decrypt\b)`

// readSecretReader is the reader-command prefix: a reader command followed
// by up to a pipe/semicolon/command boundary.
const readSecretReader = `(?i)\b(?:cat|less|more|head|tail|bat|batcat|grep|rg|sed|awk|strings|xxd|od|hexdump|jq|yq)\b[^\n;&|]*`

// readSecretHomeRE prefixes a home-relative shell fragment with any spelling
// of the home directory (`~`, `$HOME`, or `/home/<user>`).
const readSecretHomeRE = `(?:~|\$HOME|/home/[^/\s"']+)?`

// readSecretSuffix bounds a path after the location fragment.
const readSecretSuffix = `(?:/|[\s"']|$)`

// readSecretFileRE matches a reader command followed by a path under a secret
// directory — the shell-expressed twin of secretPaths (a command spells
// `~/.ssh`, `$HOME/.aws` or `/run/agenix`, never the resolved absolute path).
// It is derived from secretLocations so the shell spelling and filesystem
// paths cannot drift apart. Inside the sandbox the deny-read shadow already
// makes such reads fail at the kernel, so this rule is the BACKSTOP for the
// unsandboxed path: an approved re-run after a sandbox violation, a
// pre-approved (guard-matched) command, or a one-shot `yap send` with the
// sandbox disabled. It is not the primary read barrier — the shadow mount is.
var readSecretFileRE = buildReadSecretFileRE()

func buildReadSecretFileRE() string {
	var frags []string
	for _, path := range secretLocations {
		if strings.HasPrefix(path, "~/") {
			frags = append(frags, readSecretHomeRE+regexp.QuoteMeta(path[1:]))
		} else {
			frags = append(frags, regexp.QuoteMeta(path))
		}
	}
	return readSecretReader + "(?:" + strings.Join(frags, "|") + ")" + readSecretSuffix
}

var (
	ageKeygenRE       = regexp.MustCompile(`(?i)\bage-keygen\b`)
	ageKeygenSafeRE   = regexp.MustCompile(`(?i)\bage-keygen\b[^\n;&|]*\s-y(?:\s|$)`)
	gpgExportSecretRE = regexp.MustCompile(`(?i)\bgpg(?:2)?\b[^\n;&|]*--export-secret-(?:keys|subkeys)\b`)
	opensslKeyRE      = regexp.MustCompile(`(?i)\bopenssl\b[^\n;&|]*\b(?:rsa|ec|dsa|pkey|genrsa|genpkey|pkcs8)\b`)
)

// revealsSecretKey reports whether a command generates or exports private key
// material. age-keygen -y derives public recipients from an identity and is
// the one safe form, so it is excluded.
func revealsSecretKey(cmd string) bool {
	if ageKeygenRE.MatchString(cmd) && !ageKeygenSafeRE.MatchString(cmd) {
		return true
	}
	return gpgExportSecretRE.MatchString(cmd) || opensslKeyRE.MatchString(cmd)
}

var secretRevealRules = []Rule{
	Pattern("decrypts secret material", decryptRE),
	{Name: "reveals a secret key", Match: revealsSecretKey},
	Pattern("reads a secret file", readSecretFileRE),
}

// SecretRevealRules returns the bash guard rules for commands whose output is
// secret material. tools/bash.go appends these to its denylist; they surface
// in `yap guard` and the guard board like every other rule.
func SecretRevealRules() []Rule {
	return secretRevealRules
}
