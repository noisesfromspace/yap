// Package safety is the one responsible system for keeping the agent bounded
// and secret-free: the secrets domain (secrets.go — secret-path detection and
// the reveal guard rules), output redaction (scrub.go), SSRF protection for
// network tools (ssrf.go), the static guard-rule gate (gate.go, with the
// shell parser in shell.go that bash's rules read a command line through) that
// pauses a call for a human Run/Deny decision before it runs, and the
// bubblewrap sandbox (sandbox.go) that kernel-enforces the write barrier for
// bash and bounds the write/edit tools via the shared writable-allowlist
// policy.
package safety
