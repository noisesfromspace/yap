// The bash sandbox: a bubblewrap (bwrap) execution barrier that turns bash
// from "unsandboxed by design" into "least-privilege by default". The whole
// filesystem is bind-mounted read-only, a small allowlist of directories (the
// project dir, the session assets dir, and the Go/Nix build caches) is
// re-mounted writable, /tmp is a private temp dir that persists for the
// session, and the secret directories are shadowed by empty mounts so they
// cannot be read. A write the kernel refuses (EROFS) escalates to the human
// through the normal approval gate — the same Run/Deny the static guard rules
// use.
//
// This is the write/read barrier. It is NOT a network or confidentiality
// boundary: the network namespace is shared, so a command can still reach the
// internet and exfiltrate anything it can read.
//
// The same allowlist (WritableDirs / IsWritablePath) bounds the write and edit
// tools, so every mutating tool shares one definition of "where the agent may
// write". The escalation decision lives in the bash tool, next to the guard
// rules this complements.
package safety

import (
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"sort"
	"strings"
	"sync"
	"syscall"
	"time"

	"boers.email/yap/agent/utils"
)

// SandboxConfig is the sandbox policy for the turn, loaded from settings.json
// (`sandbox`). The zero value disables the sandbox; turn.Run fills it from
// config, defaulting Enabled to true.
type SandboxConfig struct {
	Enabled    bool
	AllowWrite []string // extra writable dirs (project dir + assets dir are always writable)
	DenyRead   []string // extra paths to shadow (the secret dirs are always shadowed)
}

var (
	sandboxMu     sync.Mutex
	sandboxPolicy SandboxConfig
	sandboxAvail  = -1 // -1 unknown, 0 unavailable, 1 active
	sandboxWarned bool
)

// SetSandboxConfig installs the sandbox policy for the turn. Cheap:
// availability is probed lazily on the first SandboxActive call and cached
// for the process.
func SetSandboxConfig(cfg SandboxConfig) {
	sandboxMu.Lock()
	sandboxPolicy = cfg
	sandboxMu.Unlock()
}

// SandboxActive reports whether commands should be sandboxed: enabled, Linux,
// bwrap on PATH, and a probe run succeeded. The first call performs the probe
// and caches it; a one-line warning is printed once when the sandbox is
// enabled but unusable.
func SandboxActive() bool {
	sandboxMu.Lock()
	defer sandboxMu.Unlock()
	if !sandboxPolicy.Enabled {
		return false
	}
	if sandboxAvail == -1 {
		sandboxAvail = 0
		if runtime.GOOS == "linux" {
			if _, err := exec.LookPath("bwrap"); err == nil && probe() == nil {
				sandboxAvail = 1
			}
		}
		if sandboxAvail == 0 && !sandboxWarned {
			fmt.Fprintln(os.Stderr, "yap: bash sandbox disabled (bubblewrap unavailable)")
			sandboxWarned = true
		}
	}
	return sandboxAvail == 1
}

// probe verifies bwrap can actually create namespaces and enforce the
// read-only root (some kernels disable unprivileged user namespaces).
func probe() error {
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "bwrap", "--ro-bind", "/", "/", "--dev", "/dev", "--proc", "/proc", "--", "true")
	cmd.Stdin = nil
	if out, err := cmd.CombinedOutput(); err != nil {
		return fmt.Errorf("bwrap probe: %v: %s", err, strings.TrimSpace(string(out)))
	}
	return nil
}

// sandboxSetup returns the bwrap flags shared by every wrapped command: the
// read-only root, a private /tmp, the writable allowlist binds, and the
// deny-read shadow mounts.
func sandboxSetup(projectDir string) []string {
	args := []string{
		"--ro-bind", "/", "/",
		"--dev", "/dev",
		"--proc", "/proc",
	}
	// Temp is writable and persists across calls within a session: a fresh
	// tmpfs made `curl -o /tmp/x` in one call vanish in the next — the exact
	// "write scratch to /tmp" habit that never took. Binding a session-scoped
	// temp dir over the temp paths keeps them writable and persistent while
	// still hiding the host's real /tmp. With no session assets dir (a one-shot
	// `yap send`) there is nothing to persist into, so the old private tmpfs
	// stays.
	if tmp := persistentTmp(); tmp != "" {
		for _, t := range tempPaths() {
			args = append(args, "--bind", tmp, t)
		}
	} else {
		args = append(args, "--tmpfs", os.TempDir())
	}
	for _, dir := range WritableDirs(projectDir) {
		args = append(args, "--bind", dir, dir)
	}
	// Build caches (Go, Nix) are writable so `go test`/`nix` don't trip the
	// read-only barrier and escalate to an unsandboxed re-run on every build.
	for _, dir := range buildCacheDirs() {
		if dir == "" {
			continue
		}
		if err := os.MkdirAll(dir, 0o700); err == nil {
			args = append(args, "--bind", dir, dir)
		}
	}
	for _, path := range shadowPaths() {
		st, err := os.Stat(path)
		if err != nil {
			continue // nonexistent deny-read path: nothing to shadow (filterExisting)
		}
		if st.IsDir() {
			args = append(args, "--tmpfs", path) // empty ephemeral dir
		} else {
			args = append(args, "--ro-bind", "/dev/null", path) // unreadable file
		}
	}
	return args
}

// tempPaths returns the temp locations the sandbox rebinds to the persistent
// per-session temp dir: the conventional /tmp, plus os.TempDir() when TMPDIR
// points elsewhere (a `nix develop` shell sets it to a per-shell dir). The
// bind hides the host's real temp files and makes temp writes land in the
// session assets dir, so they survive to the next call.
func tempPaths() []string {
	seen := map[string]bool{}
	var out []string
	add := func(p string) {
		p = filepath.Clean(p)
		if !seen[p] {
			seen[p] = true
			out = append(out, p)
		}
	}
	add("/tmp")
	if t := os.TempDir(); t != "" && t != "/tmp" {
		add(t)
	}
	return out
}

// persistentTmp is the per-session temp dir the sandbox binds over /tmp, so a
// command's temp files survive to the next call instead of vanishing with the
// per-call tmpfs. It lives under the session assets dir (cleaned with the
// session). Returns "" for a one-shot `yap send`, which has no session dir to
// persist into.
func persistentTmp() string {
	base := utils.AssetsBase()
	if base == "" || base == os.TempDir() {
		return ""
	}
	d := filepath.Join(base, "tmp")
	_ = os.MkdirAll(d, 0o700)
	return d
}

// buildCacheDirs returns the host cache directories Go and Nix write into
// from inside the sandbox. They are per-user caches (not secret material), and
// binding them writable stops `go test`/`nix` from tripping the read-only
// barrier and escalating to an unsandboxed re-run on every build. They are
// sandbox-only: the write/edit allowlist (IsWritablePath) deliberately does
// not include them, since no purpose-built file tool targets a build cache.
func buildCacheDirs() []string {
	home, err := os.UserHomeDir()
	if err != nil || home == "" {
		return nil
	}
	userCache, _ := os.UserCacheDir()
	if userCache == "" {
		userCache = filepath.Join(home, ".cache")
	}
	out := []string{
		filepath.Join(userCache, "go-build"),    // go build cache (GOCACHE)
		filepath.Join(userCache, "nix"),         // nix fetcher/store cache
		filepath.Join(home, "go", "pkg", "mod"), // go module cache (GOMODCACHE)
	}
	if g := os.Getenv("GOCACHE"); g != "" {
		out = append(out, g)
	}
	if g := os.Getenv("GOMODCACHE"); g != "" {
		out = append(out, g)
	}
	return out
}

// SandboxWrap builds the bwrap-wrapped command for `command`. projectDir is
// the resolved working directory (the bash tool's cwd) and is always in the
// writable allowlist. The returned command runs bwrap with the sandbox setup
// and then `bash -c command`.
func SandboxWrap(command, projectDir string) *exec.Cmd {
	args := append(sandboxSetup(projectDir), "--", "bash", "-c", command)
	cmd := exec.Command("bwrap", args...)
	cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	if projectDir != "" {
		cmd.Dir = projectDir
	}
	return cmd
}

// readOnlyFSRe matches the kernel's EROFS strerror at the end of an error
// line (`touch: cannot touch 'x': Read-only file system`), so a command that
// merely prints the phrase (cat'ing a document about it) does not trip the
// escalation.
var readOnlyFSRe = regexp.MustCompile(`(?m):\s*Read-only file system\s*$`)

// SandboxViolated reports whether a sandboxed run hit the read-only write
// barrier: the command exited non-zero AND its output carries the EROFS
// signal. A non-zero exit alone is common (a failing test); the phrase alone
// can be legitimate content. Together they mean a write was blocked.
func SandboxViolated(text string, exitCode int) bool {
	return exitCode != 0 && readOnlyFSRe.MatchString(text)
}

// WritableDirs returns the directories re-mounted writable inside the
// sandbox: the project dir, the session assets dir, and any configured
// extras, deduplicated and as absolute paths. "/" stays read-only, and the
// temp dir itself (os.TempDir(), normally /tmp) is skipped here — the sandbox
// handles temp separately (see tempPaths/persistentTmp), and adding it to
// this list would let write/edit target the host's real /tmp. A project or
// assets dir UNDER the temp dir is still bound (the bind overrides whatever
// the sandbox mounts at /tmp), so `go test` running from a temp checkout
// keeps working. This list is the canonical "where the agent may write"
// policy: IsWritablePath and the write/edit guard rules read it too.
func WritableDirs(projectDir string) []string {
	var dirs []string
	seen := map[string]bool{}
	tmp := os.TempDir()
	add := func(d string) {
		if d == "" {
			return
		}
		abs, err := filepath.Abs(d)
		if err != nil {
			return
		}
		abs = filepath.Clean(abs)
		if abs == "/" || abs == tmp || abs == "/tmp" {
			return
		}
		if seen[abs] {
			return
		}
		seen[abs] = true
		dirs = append(dirs, abs)
	}
	add(projectDir)
	add(utils.AssetsBase())
	for _, d := range sandboxPolicy.AllowWrite {
		add(utils.ExpandHome(d))
	}
	return dirs
}

// IsWritablePath reports whether path is, or resolves into, a directory the
// agent may write to without approval: the project dir (frontend cwd), the
// session assets dir, the configured extras, or the system temp dir. It is
// the write/edit guard predicate — a target outside the allowlist pauses for
// Run/Deny. Relative paths resolve against the frontend cwd (the project),
// matching the bash tool's "default: the Neovim cwd" semantics; symlinks are
// resolved so a link out of the project cannot pass (a write follows the link
// and lands outside).
func IsWritablePath(p string) bool {
	p = utils.ToolPath(p)
	if strings.TrimSpace(p) == "" {
		return false
	}
	abs := filepath.Clean(p)
	// Resolve symlinks first: a link out of the project must not count as
	// writable. ResolvePath falls back to the cleaned abs path when nothing
	// resolves, so a brand-new file under the project still passes.
	if resolved, err := utils.ResolvePath(abs); err == nil {
		abs = resolved
	}
	dirs := WritableDirs(projectDir())
	// Scratch writes never prompt. Both the conventional /tmp and os.TempDir()
	// count: a harness that sets TMPDIR to a per-process dir (`nix develop` uses
	// /tmp/nix-shell.*) must not make plain /tmp writes suddenly prompt.
	dirs = append(dirs, os.TempDir(), "/tmp")
	return under(abs, dirs)
}

// projectDir is the writable-allowlist anchor: the frontend cwd, or the
// process cwd when the frontend sent none (one-shot `yap send`).
func projectDir() string {
	if cwd := utils.FrontendCwd(); cwd != "" {
		return cwd
	}
	cwd, _ := os.Getwd()
	return cwd
}

// OutsideWritableRule builds a guard rule that pauses a mutating tool (write,
// edit) whose target is outside the writable allowlist. It is the
// project-bound counterpart to SecretPathRule: the sandbox bounds bash, this
// bounds the purpose-built file tools, both against the same WritableDirs
// policy. read is deliberately NOT bounded — reading is not a write.
func OutsideWritableRule(name string) Rule {
	return Rule{Name: name, Match: func(p string) bool {
		return strings.TrimSpace(p) != "" && !IsWritablePath(p)
	}}
}

// under reports whether path equals dir or sits under it.
func under(path string, dirs []string) bool {
	for _, d := range dirs {
		if pathIsUnder(path, d) {
			return true
		}
	}
	return false
}

// shadowPaths returns the paths the sandbox hides (empty mounts) so bash
// cannot read them: the built-in secret directories plus any configured
// extras, symlink-resolved and deduplicated. Paths are returned shallowest
// first and a path covered by a listed ancestor is dropped — a shadowed
// directory already hides everything under it, and mounting a descendant
// first would fail (bwrap cannot create a mountpoint under a read-only
// parent).
func shadowPaths() []string {
	seen := map[string]bool{}
	var raw []string
	add := func(p string) {
		if p == "" {
			return
		}
		if resolved, err := utils.ResolvePath(p); err == nil {
			p = resolved
		}
		if p == "/" || seen[p] {
			return
		}
		seen[p] = true
		raw = append(raw, p)
	}
	for _, p := range SecretPaths() {
		add(p)
	}
	for _, p := range sandboxPolicy.DenyRead {
		add(utils.ExpandHome(p))
	}
	sep := string(filepath.Separator)
	sort.Slice(raw, func(i, j int) bool { return strings.Count(raw[i], sep) < strings.Count(raw[j], sep) })
	var out []string
	for _, p := range raw {
		covered := false
		for _, q := range out {
			if strings.HasPrefix(p, q+sep) {
				covered = true
				break
			}
		}
		if !covered {
			out = append(out, p)
		}
	}
	return out
}
