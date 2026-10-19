package safety

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
	// Bearer tokens (including shorter opaque tokens).
	regexp.MustCompile(`(?i)\bBearer\s+[A-Za-z0-9_\-\.~+/=]{8,}`),
	// Vendor token prefixes: shapes that identify themselves, so no key name
	// is needed. These are the leaks a plain `KEY=value` scan misses when the
	// secret is pasted on its own (a diff, a log line, a shell trace).
	regexp.MustCompile(`\bgh[pousr]_[A-Za-z0-9]{20,}`),                                    // GitHub PAT/app/refresh/server/user
	regexp.MustCompile(`\bsk-[A-Za-z0-9_\-]{20,}`),                                        // OpenAI/Anthropic-style
	regexp.MustCompile(`\bxox[baprs]-[A-Za-z0-9\-]{10,}`),                                 // Slack
	regexp.MustCompile(`\bAIza[0-9A-Za-z_\-]{35}\b`),                                      // Google API key
	regexp.MustCompile(`\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}`), // JWT
}

// scrubAssign matches named secret assignments, including JSON string values.
// The key may carry an identifier prefix (`AWS_SECRET_ACCESS_KEY`, `MY_API_KEY`),
// so it is matched from the start of the identifier run instead of behind a
// `\b` — a word boundary never exists between `_` and a letter, so the common
// `OPENAI_API_KEY=` shape slipped through unredacted. Groups: 1 = key name
// (with any prefix), 2 = operator + optional opening quote, 3 = value (a
// `{...}` object counts as one value so `password={x}` is not skipped).
var scrubAssign = regexp.MustCompile(`(?i)([A-Za-z0-9_]*(?:api[_-]?key|apikey|secret[_-]?(?:access[_-]?)?key|access[_-]?key|private[_-]?key|client[_-]?secret|api[_-]?secret|access[_-]?token|auth[_-]?token|refresh[_-]?token|password|passwd|authorization))(["']?\s*[:=]\s*["']?)([^\s"',;}{]+|\{[^{}]*\})`)

// Scrub redacts obvious secrets from s and repairs bytes that are not valid
// UTF-8 to U+FFFD. Tool output is where raw bytes enter the session, which is
// UTF-8: a stray byte in it makes Nvim read the whole transcript back as
// latin1 ('fileencodings' falls back there) and re-encode it on the next
// :write — one 0xBF per character outside latin1.
func Scrub(s string) string {
	s = strings.ToValidUTF8(s, "\uFFFD")
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
