// Package utils holds the small, leaf helpers shared across the yap agent
// that have no tighter home: path and environment-root resolution
// (paths.go), argument slimming for buffer-visible tool headers (slim.go),
// and unified diffs (diff.go).
//
// The two larger clusters that used to live here now have their own
// packages: the framed wire protocol and turn/process runtime (agent/wire)
// and the security primitives — secret detection/redaction, SSRF checks and
// the static guard-rule gate (agent/safety).
package utils
