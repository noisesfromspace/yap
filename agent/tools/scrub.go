package tools

import (
	"regexp"
	"strings"
)

// scrub is a local, deterministic best-effort secret redactor. It runs on
// tool results before they enter context or the audit log, so secrets read
// off disk (or emitted by a command) do not reach the provider or persist.
// It is regex-based only: a generic entropy scanner would flag every long
// hash/blob in code and degrade the agent, so high-signal named patterns
// are preferred. It is not a substitute for not reading secrets.
//
// Whole-match patterns are replaced with redacted; the assignment pattern
// keeps the key name and drops the value.
const redacted = "[REDACTED]"

var scrubWhole = []*regexp.Regexp{
	// PEM private keys (RSA, EC, OPENSSH, ENCRYPTED, ...).
	regexp.MustCompile(`(?s)-----BEGIN (?:[A-Z0-9 ]*)?PRIVATE KEY-----.*?-----END (?:[A-Z0-9 ]*)?PRIVATE KEY-----`),
	// age secret keys (the agenix identity format).
	regexp.MustCompile(`AGE-SECRET-KEY-1[A-Z0-9]{40,}`),
	// AWS access key IDs (the secret key is entropy-only and not matched).
	regexp.MustCompile(`\bAKIA[0-9A-Z]{16}\b`),
	// Bearer tokens.
	regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9_\-\.]{16,}`),
}

// scrubAssign matches `name=value` / `name: value` for common secret names
// with a reasonably long value; only the value is dropped.
// Groups: 1 = key name, 2 = operator + optional opening quote, 3 = value.
var scrubAssign = regexp.MustCompile(`(?i)\b(api[_-]?key|apikey|secret[_-]?key|client[_-]?secret|access[_-]?token|auth[_-]?token|password|passwd|authorization)(\s*[:=]\s*["']?)([A-Za-z0-9_\-\./+=]{16,})`)

// Scrub redacts obvious secrets from s.
func Scrub(s string) string {
	for _, re := range scrubWhole {
		s = re.ReplaceAllString(s, redacted)
	}
	s = scrubAssignments(s)
	return s
}

// scrubAssignments replaces just the value of each assignment, keeping the
// key and any surrounding quotes balanced (so `api_key="..."` stays quoted).
func scrubAssignments(s string) string {
	var b strings.Builder
	last := 0
	for _, m := range scrubAssign.FindAllStringSubmatchIndex(s, -1) {
		b.WriteString(s[last:m[0]])
		b.WriteString(s[m[2]:m[3]]) // key name
		b.WriteString(s[m[4]:m[5]]) // operator + opening quote
		b.WriteString(redacted)
		last = m[1] // the closing quote (outside the match) stays in the tail
	}
	b.WriteString(s[last:])
	return b.String()
}
