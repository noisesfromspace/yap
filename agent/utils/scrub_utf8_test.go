package utils

import (
	"strings"
	"testing"
	"unicode/utf8"
)

// A tool result that dumped binary (a cat of an ELF, a head -c of an image)
// lands in the session file. Raw bytes there make Nvim read the whole
// transcript back as latin1 — 'fileencodings' falls back when a file is not
// valid UTF-8 — and every later :write then re-encodes it, turning each
// character outside latin1 into a single 0xBF byte. Scrub is the single
// normalizer for tool output, so it repairs them.
func TestScrubRepairsInvalidUTF8(t *testing.T) {
	const in = "yap -> /home/martijn/.cache/yap/bin/yap\n\x7fELF\x02\x01 \xca\x8b\x00 \xbf end"
	got := Scrub(in)
	if !utf8.ValidString(got) {
		t.Fatalf("invalid utf-8 survived Scrub: %q", got)
	}
	if !strings.Contains(got, "\uFFFD") {
		t.Fatalf("stray bytes were not replaced: %q", got)
	}
	if !strings.HasPrefix(got, "yap -> /home/martijn/.cache/yap/bin/yap\n\x7fELF\x02\x01") {
		t.Fatalf("readable context was rewritten: %q", got)
	}
	if !strings.HasSuffix(got, " end") {
		t.Fatalf("tail was rewritten: %q", got)
	}

	// Valid multi-byte text is left exactly as it is.
	const text = "plain — dash · dot ─ rule ✅\n"
	if Scrub(text) != text {
		t.Fatalf("valid utf-8 was rewritten: %q", Scrub(text))
	}
}
