// Package safety is the one responsible system for "secret material must
// not reach the transcript": the secrets domain (secrets.go — secret-path
// detection and the reveal guard rules), output redaction (scrub.go), SSRF
// protection for network tools (ssrf.go), and the static guard-rule gate
// (gate.go) that pauses a call for a human Run/Deny decision before it runs.
package safety
