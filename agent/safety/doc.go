// Package safety is the one responsible system for keeping the agent bounded
// and secret-free: the secrets domain (secrets.go — secret-path detection and
// the reveal guard rules), output redaction (scrub.go), SSRF protection for
// network tools (ssrf.go), the static guard-rule gate (gate.go) that pauses a
// call for a human Run/Deny decision before it runs, and the bubblewrap
// sandbox (sandbox.go) that kernel-enforces the write/read barrier for bash
// and curl and bounds the write/edit tools via the shared writable-allowlist
// policy.
package safety
