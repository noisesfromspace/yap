// The shell domain is the lens the bash guard rules use on a command line:
// instead of regexes over the raw text, a rule sees the commands that will
// actually run.
//
// Why a parser. Text rules match words in the wrong place. `git commit -m
// "… ssh and systemctl …"` and `rg -n "crontab -e" docs/` are not remote
// shells, but a `\bssh\b` pattern cannot tell; anchoring the pattern at
// command position helps and is still a guess (a quoted `|` reads as a
// separator). The syntax tree knows which word is the command, what its
// arguments are, whether stdin comes from a pipeline, and whether the command
// sits inside a substitution — so a rule states an intent, and quoting,
// comments and argument text stop being a source of both false positives and
// bypasses. `timeout 20 ssh host`, `cd /tmp && ssh host` and `sudo -n ssh
// host` are one command each, not three patterns to keep in sync.

package safety

import (
	"os"
	"path/filepath"
	"strings"

	"mvdan.cc/sh/v3/syntax"
)

// ShellCmd is one simple command lifted out of a parsed shell program, in the
// shape a rule reasons about.
type ShellCmd struct {
	// Name is the command word: the file's base name with the wrappers in
	// shellWrappers stripped, so `timeout 20 /usr/bin/ssh host` arrives as
	// "ssh" with args ["host"].
	Name string
	// Args are the words after the command word: quoted text unquoted, `~`
	// and `$HOME` expanded, and anything unresolvable (`$x`, `$(…)`, a glob)
	// rendered as an opaque placeholder so it can never read as a real flag
	// or path.
	Args []string
	// Pipe reports that the command's stdin is a pipeline stage. That is what
	// makes a bare `sh` a remote-code sink instead of a script runner.
	Pipe bool
	// Subst reports that the command runs inside a command substitution
	// (`$(…)`, backticks, `<(…)`), so its output feeds another command.
	Subst bool
	// Priv reports that the command was reached through sudo/doas.
	Priv bool
}

// Has reports whether one of the command's arguments is exactly one of names.
func (c ShellCmd) Has(names ...string) bool {
	return HasArg(c.Args, names...)
}

// Sub returns the command's subcommand: the first argument that is not a flag,
// with the arguments after it.
func (c ShellCmd) Sub() (string, []string) {
	return Sub(c.Args)
}

// HasArg reports whether args contains one of words, exactly. Rules ask about
// flags and subcommand words this way rather than by substring, so `-d` does
// not match `-data` and `push` does not match `--push-option`.
func HasArg(args []string, words ...string) bool {
	for _, a := range args {
		for _, w := range words {
			if a == w {
				return true
			}
		}
	}
	return false
}

// Sub returns the first word in args that is not a flag, with the words after
// it: the subcommand of git, npm, docker, systemctl. Global options that take a
// separate value (`git -C dir push`) are skipped, so the subcommand is not one
// `-C` away from silent.
func Sub(args []string) (string, []string) {
	for i := 0; i < len(args); i++ {
		switch a := args[i]; {
		case a == "-C", a == "-c", a == "--git-dir", a == "--work-tree",
			a == "--namespace", a == "--exec-path":
			i++
		case strings.HasPrefix(a, "-"):
		default:
			return a, args[i+1:]
		}
	}
	return "", nil
}

// Shell builds a guard rule over the parsed command line, for rules that need
// the whole program (a pipeline's shape, a command substitution, a wrapper).
// A command that does not parse trips no shell rule: bash would refuse to run
// it too, and the sandbox is unaffected either way.
func Shell(name string, match func(cmds []ShellCmd) bool) Rule {
	return Rule{Name: name, Shell: match}
}

// ShellAny is Shell for the common case: trip when any command in the program
// satisfies match. Wrappers are already stripped by ParseShell.
func ShellAny(name string, match func(c ShellCmd) bool) Rule {
	return Shell(name, func(cmds []ShellCmd) bool {
		for _, c := range cmds {
			if match(c) {
				return true
			}
		}
		return false
	})
}

// ParseShell parses a bash command line and returns every simple command it
// would run, at any depth, or ok=false when the program does not parse. The
// second return value is the caller's cue that nothing could be inspected.
func ParseShell(src string) (cmds []ShellCmd, ok bool) {
	file, err := syntax.NewParser(syntax.Variant(syntax.LangBash)).Parse(strings.NewReader(src), "")
	if err != nil {
		return nil, false
	}
	home, _ := os.UserHomeDir()
	walkStmts(file.Stmts, shellCtx{home: home}, &cmds)
	return cmds, true
}

// shellCtx carries what the walk cannot get from the node: the home directory
// words expand against, and whether we are inside a pipe or a substitution.
type shellCtx struct {
	home  string
	pipe  bool
	subst bool
}

func walkStmts(stmts []*syntax.Stmt, ctx shellCtx, out *[]ShellCmd) {
	for _, st := range stmts {
		if st.Cmd != nil {
			walkCmd(st.Cmd, ctx, out)
		}
	}
}

func walkCmd(cmd syntax.Command, ctx shellCtx, out *[]ShellCmd) {
	switch c := cmd.(type) {
	case *syntax.CallExpr:
		if sc, ok := callCmd(c, ctx, out); ok {
			*out = append(*out, sc)
		}
	case *syntax.BinaryCmd:
		walkStmts([]*syntax.Stmt{c.X}, ctx, out)
		right := ctx
		if c.Op == syntax.Pipe || c.Op == syntax.PipeAll {
			right.pipe = true
		}
		walkStmts([]*syntax.Stmt{c.Y}, right, out)
	case *syntax.Subshell:
		walkStmts(c.Stmts, ctx, out)
	case *syntax.Block:
		walkStmts(c.Stmts, ctx, out)
	case *syntax.IfClause:
		for ic := c; ic != nil; ic = ic.Else {
			walkStmts(ic.Cond, ctx, out)
			walkStmts(ic.Then, ctx, out)
		}
	case *syntax.WhileClause:
		walkStmts(c.Cond, ctx, out)
		walkStmts(c.Do, ctx, out)
	case *syntax.ForClause:
		walkStmts(c.Do, ctx, out)
	case *syntax.CaseClause:
		for _, item := range c.Items {
			walkStmts(item.Stmts, ctx, out)
		}
	case *syntax.DeclClause: // declare/local/export/readonly/typeset
		for _, a := range c.Args {
			if a.Value != nil {
				walkWord(a.Value, ctx, out)
			}
		}
	case *syntax.FuncDecl:
		if c.Body != nil {
			walkStmts([]*syntax.Stmt{c.Body}, ctx, out)
		}
	case *syntax.TimeClause:
		if c.Stmt != nil {
			walkStmts([]*syntax.Stmt{c.Stmt}, ctx, out)
		}
	case *syntax.CoprocClause:
		if c.Stmt != nil {
			walkStmts([]*syntax.Stmt{c.Stmt}, ctx, out)
		}
	}
}

// callCmd turns a simple command into a ShellCmd and walks the substitutions
// in its words: `X=$(curl …) cmd` and `cmd $(curl …)` run the fetch first.
func callCmd(c *syntax.CallExpr, ctx shellCtx, out *[]ShellCmd) (ShellCmd, bool) {
	for _, a := range c.Assigns {
		if a.Value != nil {
			walkWord(a.Value, ctx, out)
		}
	}
	for _, w := range c.Args {
		walkWord(w, ctx, out)
	}
	if len(c.Args) == 0 {
		return ShellCmd{}, false
	}
	words := make([]string, 0, len(c.Args))
	for _, w := range c.Args {
		words = append(words, renderWord(w, ctx.home))
	}
	name, args, priv := unwrap(filepath.Base(words[0]), words[1:])
	return ShellCmd{Name: name, Args: args, Pipe: ctx.pipe, Subst: ctx.subst, Priv: priv}, true
}

// shellWrappers are the commands that exist only to launch the next command in
// their argument list. Stripping them is what keeps the rules about the
// command that runs, not about its launcher: `nohup timeout 30 nice ssh host`
// is an ssh. The list is Claude Code's, plus bash's `builtin`.
var shellWrappers = map[string]bool{
	"sudo": true, "sudoedit": true, "doas": true, "env": true, "nohup": true,
	"nice": true, "time": true, "timeout": true, "command": true,
	"builtin": true, "stdbuf": true,
}

// unwrap strips wrappers and reports whether the command was elevated. A
// wrapper with no inner command (`env` alone) is returned as itself.
func unwrap(name string, args []string) (string, []string, bool) {
	priv := false
	for shellWrappers[name] {
		if name == "sudo" || name == "sudoedit" || name == "doas" {
			priv = true
		}
		i := commandArg(args)
		if i < 0 {
			return name, args, priv
		}
		name, args = filepath.Base(args[i]), args[i+1:]
	}
	return name, args, priv
}

// wrapperValueFlags are wrapper options that take a separate value, so the
// value is not mistaken for the command: `sudo -u root ssh host`,
// `timeout -s KILL 5 ssh host`. The list is short on purpose — a flag whose
// value is a number (`nice -n 10`, `timeout -k 5`) is already skipped, and a
// letter that collides across wrappers (sudo -s = shell, timeout -s = signal)
// is kept only where skipping the value of the harmless form is free.
var wrapperValueFlags = map[string]bool{
	"-u": true, "-g": true, "-p": true, "-U": true, "-C": true, "-R": true,
	"-s": true,
}

// commandArg returns the index of the argument that names the command a wrapper
// will run: flags, their values, `NAME=value` assignments and bare numbers or
// durations (`timeout 30`) are skipped. -1 when there is none.
func commandArg(args []string) int {
	for i := 0; i < len(args); i++ {
		a := args[i]
		if wrapperValueFlags[a] {
			i++
			continue
		}
		if a == "" || strings.HasPrefix(a, "-") || strings.Contains(a, "=") || isQuantity(a) {
			continue
		}
		return i
	}
	return -1
}

// isQuantity reports whether s is a bare number or a duration: `30`, `20s`,
// `5m`, `1h`.
func isQuantity(s string) bool {
	digits := strings.TrimSuffix(strings.TrimSuffix(strings.TrimSuffix(s, "s"), "m"), "h")
	if digits == "" {
		return false
	}
	for _, r := range digits {
		if r < '0' || r > '9' {
			return false
		}
	}
	return true
}

// renderWord flattens a word to the text a rule inspects. Quoted text is
// unquoted, `~` and `$HOME` expand (so a secret path is one comparison, not a
// second regex), and anything that cannot be resolved statically becomes an
// opaque placeholder.
func renderWord(w *syntax.Word, home string) string {
	var b strings.Builder
	for _, part := range w.Parts {
		renderPart(part, home, &b)
	}
	return b.String()
}

// opaque markers: an unresolvable word can never be mistaken for a flag or a
// path, and can never contribute an argument a rule reads as meaningful.
const (
	opaqueArg   = "$…"
	opaqueSubst = "$(…)"
	opaqueOther = "…"
)

func renderPart(part syntax.WordPart, home string, b *strings.Builder) {
	switch p := part.(type) {
	case *syntax.Lit:
		b.WriteString(expandHomeLit(p.Value, home))
	case *syntax.SglQuoted:
		b.WriteString(p.Value)
	case *syntax.DblQuoted:
		for _, inner := range p.Parts {
			renderPart(inner, home, b)
		}
	case *syntax.ParamExp:
		if home != "" && p.Param != nil && p.Param.Value == "HOME" && p.Index == nil && p.Slice == nil && p.Repl == nil && p.Exp == nil {
			b.WriteString(home)
			return
		}
		b.WriteString(opaqueArg)
	case *syntax.CmdSubst, *syntax.ProcSubst:
		b.WriteString(opaqueSubst)
	default:
		b.WriteString(opaqueOther)
	}
}

// expandHomeLit expands a leading `~/` the way the shell would. Tilde
// expansion is the one expansion the parser leaves to the caller.
func expandHomeLit(v, home string) string {
	if home != "" && strings.HasPrefix(v, "~/") {
		return home + v[1:]
	}
	return v
}

// walkWord recurses into the substitutions inside a word.
func walkWord(w *syntax.Word, ctx shellCtx, out *[]ShellCmd) {
	for _, part := range w.Parts {
		walkPart(part, ctx, out)
	}
}

func walkPart(part syntax.WordPart, ctx shellCtx, out *[]ShellCmd) {
	switch p := part.(type) {
	case *syntax.CmdSubst:
		inner := ctx
		inner.subst = true
		walkStmts(p.Stmts, inner, out)
	case *syntax.ProcSubst:
		inner := ctx
		inner.subst = true
		walkStmts(p.Stmts, inner, out)
	case *syntax.DblQuoted:
		for _, nested := range p.Parts {
			walkPart(nested, ctx, out)
		}
	}
}
