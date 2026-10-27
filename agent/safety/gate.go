package safety

import "regexp"

// The gate is a tool call's pre-execution approval check: the call either
// runs immediately or pauses the turn for an explicit Run/Deny. The rules are
// static and declared in the tool's own source file (see tools.Gate), so there
// is no model in the loop and no advisory middle tier.
//
// A rule inspects one of two views of the call. A path-taking tool (read,
// write, edit, search, curl) inspects the text the call names. A command-line
// tool (bash) inspects the parsed shell program (shell.go), so its rules talk
// about the commands that will run rather than about words that happen to
// appear in the line. Neither view is a security boundary: the sandbox
// (sandbox.go) is, and it bounds exactly one thing — filesystem writes and
// reads. The gate is the tripwire in front of what the sandbox cannot see:
// network egress, remote side effects, privilege escalation and secret
// material. A rule that only restates the write barrier (`rm -rf /`, a
// redirect onto /etc) is deliberately not here — the kernel refuses it, the
// refusal escalates, and the human decides once instead of twice.

// Rule is one static approval rule for a tool call. Rules are declared in the
// tool's source file, in order; the first match supplies the reason shown in
// the approval notification, the audit log and the guard board.
type Rule struct {
	// Name is the short human label ("sudo", "remote content executed by
	// shell").
	Name string
	// Match reports whether the call's inspected text trips the rule.
	Match func(text string) bool
	// Shell reports whether the parsed command line trips the rule. Build it
	// with Shell or ShellAny instead of assigning directly. Only the tools
	// that run commands use it; a rule set with no Shell rule never parses.
	Shell func(cmds []ShellCmd) bool
}

// Pattern builds a rule that matches text against a regular expression. The
// expression is a compile-time constant: a bad one panics at init.
func Pattern(name, expr string) Rule {
	re := regexp.MustCompile(expr)
	return Rule{Name: name, Match: re.MatchString}
}

// MatchRules returns the name of the first rule matching text, or "" when the
// call may run (rules are ordered). The command line is parsed at most once
// per call, and only when a shell rule is reached.
func MatchRules(rules []Rule, text string) string {
	var cmds []ShellCmd
	parsed := false
	for _, r := range rules {
		switch {
		case r.Shell != nil:
			if !parsed {
				cmds, _ = ParseShell(text)
				parsed = true
			}
			if r.Shell(cmds) {
				return r.Name
			}
		case r.Match != nil && r.Match(text):
			return r.Name
		}
	}
	return ""
}
