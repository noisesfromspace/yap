// Package utils holds the small, leaf helpers shared across the yap agent
// that have no tighter home: path and environment-root resolution
// (paths.go), argument slimming for buffer-visible tool headers (slim.go),
// and unified diffs (diff.go).
//
// The framed wire protocol and turn/process runtime live in agent/wire; the
// security primitives — secret detection/redaction, SSRF checks and the static
// guard-rule gate — in agent/safety.
package utils
