package main

import (
	"strings"
	"testing"
)

func TestBacktickFence(t *testing.T) {
	cases := []struct {
		in   string
		want string
	}{
		{"no fences", "```"},
		{"```\ncode", "````"},
		{"`````\nx", "``````"},
		{"~~~\nnot backticks", "```"}, // tildes never close a backtick fence
	}
	for _, c := range cases {
		if got := backtickFence(c.in); got != c.want {
			t.Errorf("backtickFence(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFenceResult(t *testing.T) {
	got := fenceResult("read", `{"path":"/tmp/x.py"}`, "print(1)")
	if want := "```python\nprint(1)\n```"; got != want {
		t.Errorf("fenceResult(read .py) = %q, want %q", got, want)
	}

	// A result containing its own ``` fence is wrapped in a longer fence so
	// the inner fence is content, not an early closer.
	got = fenceResult("bash", `{"command":"cat x"}`, "```\ncode\n```")
	if !strings.HasPrefix(got, "````\n") || !strings.HasSuffix(got, "\n````") {
		t.Errorf("fenceResult(bash with inner fence) = %q", got)
	}
}
