package turn

import (
	"boers.email/yap/agent/document"
	"boers.email/yap/agent/llm"
)

// NativeHistory keeps one session's native message array between turns, so the
// next turn replays the exact items the provider already saw — native tool
// calls and results, and reasoning items with their provider metadata — instead
// of re-flattening the transcript into assistant text.
//
// It is a cache, never conversation state (R-buffer-only-state): the buffer
// stays the only source of truth. load only succeeds when the flattened input
// still starts with what was sent last turn *and* the transcript still shows
// exactly the output that turn produced, so any edit falls back to a cold
// start — precisely the behaviour without a cache. It lives in the serve
// process, so a restart is a cold start too (R-prompt-cache).
type NativeHistory struct {
	key    string             // provider + model the array was built for
	base   []document.Message // flattened input, before the request-only tail
	expect []document.Message // what this turn's own output adds to the transcript
	full   []string           // visible transcript up to this turn (thinking included)
	native []llm.Message      // the exact array, provider metadata intact
}

// cacheKey names the provider/model a native array belongs to. A switch starts
// cold: the items were produced by, and are only valid for, one model.
func cacheKey(provider, model string) string {
	return provider + "\x00" + model
}

// replay returns the native array to extend and how many leading elements of
// base it already covers, or nil when this turn cannot replay: a different
// model, a shorter history, an edited transcript, or a turn that never stored.
// base is the flattened transcript (thinking stripped); full is VisibleLines
// of the raw transcript, so edits to skipped regions — thinking above all —
// also invalidate the entry.
func (h *NativeHistory) replay(key string, base []document.Message, full []string) ([]llm.Message, int) {
	if h == nil || h.key != key || len(h.native) == 0 || len(h.expect) == 0 {
		return nil, 0
	}
	covered := len(h.base) + len(h.expect)
	if len(base) < covered {
		return nil, 0
	}
	for i, m := range h.base {
		if base[i] != m {
			return nil, 0
		}
	}
	for i, m := range h.expect {
		if base[len(h.base)+i] != m {
			return nil, 0
		}
	}
	if len(full) < len(h.full) {
		return nil, 0
	}
	for i, line := range h.full {
		if full[i] != line {
			return nil, 0
		}
	}
	return h.native, covered
}

// store records this turn's input and native array for the next turn. base is
// the flattened input before the request-only tail; expect is what the turn's
// own output adds to the transcript; full is the visible transcript through
// this turn (thinking included). A later edit to any of them invalidates the
// entry.
func (h *NativeHistory) store(key string, base, expect []document.Message, full []string, native []llm.Message) {
	h.key = key
	h.base = base
	h.expect = expect
	h.full = append([]string(nil), full...)
	h.native = append([]llm.Message(nil), native...)
}
