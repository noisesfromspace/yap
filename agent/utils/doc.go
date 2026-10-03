// Package utils holds small, shared helpers used across the yap agent:
// the yap:event audit-log emitter, process-group tracking for cleaning up
// in-flight tool processes on interrupt, argument slimming for the
// buffer-visible tool headers, path guarding, SSRF checks, secret scrubbing,
// safety scanning, and unified diffs.
package utils
