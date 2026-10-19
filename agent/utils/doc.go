// Package utils holds small, shared helpers used across the yap agent:
// the yap:event audit-log emitter, process-group tracking for cleaning up
// in-flight tool processes on interrupt, argument slimming for the
// buffer-visible tool headers, path resolution (paths.go), the static
// guard-rule gate (gate.go) with its secret knowledge (secrets.go) and
// redaction (scrub.go), SSRF checks, and unified diffs.
package utils
