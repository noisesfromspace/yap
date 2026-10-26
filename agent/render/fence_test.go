package render

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
		{"    ```\ncode", "````"},     // >3-space indent: CommonMark content, but the markdown grammar yap renders with closes on it
		{"          ```\nx", "````"},  // deeply indented sample (Nix description string)
		{"\t```\nx", "````"},          // tab indent: same grammar quirk
		{"+```\ncode", "````"},        // diff-added fence (yap:ui line) closes the wrapper early
		{"-```\ncode", "````"},        // diff-removed fence
		{"+````\nx", "`````"},         // longer diff-added fence
		{"abc ```\n", "````"},         // run after a word token, whitespace to EOL
		{"text ``` more", "```"},      // run followed by an info string: keeps the fence open, not counted
	}
	for _, c := range cases {
		if got := backtickFence(c.in); got != c.want {
			t.Errorf("backtickFence(%q) = %q, want %q", c.in, got, c.want)
		}
	}
}

func TestFenceResult(t *testing.T) {
	got := FenceResult("read", `{"path":"/tmp/x.py"}`, "print(1)")
	if want := "```python\nprint(1)\n```"; got != want {
		t.Errorf("FenceResult(read .py) = %q, want %q", got, want)
	}

	// A result containing its own ``` fence is wrapped in a longer fence so
	// the inner fence is content, not an early closer.
	got = FenceResult("bash", `{"command":"cat x"}`, "```\ncode\n```")
	if !strings.HasPrefix(got, "````\n") || !strings.HasSuffix(got, "\n````") {
		t.Errorf("FenceResult(bash with inner fence) = %q", got)
	}
}

func TestResultFence(t *testing.T) {
	cases := []struct {
		name, args string
		wantLang   string
		wantOK     bool
	}{
		{"read", `{"path":"/tmp/x.py"}`, "python", true},
		{"read", `{"path":"/tmp/x.yaml"}`, "yaml", true},
		{"read", `{"path":"/tmp/x.kt"}`, "kotlin", true},
		{"read", `{"path":"/tmp/x.cs"}`, "c_sharp", true},
		{"read", `{"path":"/tmp/x.tf"}`, "hcl", true},
		{"read", `{"path":"/tmp/x.vue"}`, "vue", true},
		{"read", `{"path":"/tmp/x.unknown"}`, "", true}, // unrecognized ext: plain fence
		{"read", `{"path":"/tmp/Dockerfile"}`, "dockerfile", true},
		{"read", `{"path":"/tmp/Makefile"}`, "make", true},
		{"fetch", `{"url":"http://x"}`, "markdown", true},
		{"bash", `{"command":"ls"}`, "", true},
		{"search", `{"pattern":"x"}`, "", true},
		{"glob", `{"pattern":"*.go"}`, "", true},
		{"write", `{"path":"/tmp/x","content":"y"}`, "", false},
		{"edit", `{"path":"/tmp/x","edits":[]}`, "", false},
	}
	for _, c := range cases {
		lang, ok := resultFence(c.name, c.args)
		if lang != c.wantLang || ok != c.wantOK {
			t.Errorf("resultFence(%s, %s) = (%q, %v), want (%q, %v)",
				c.name, c.args, lang, ok, c.wantLang, c.wantOK)
		}
	}
}

func TestUnclosedFence(t *testing.T) {
	cases := []struct {
		lines []string
		want  string
	}{
		{[]string{"plain", "text"}, ""},
		{[]string{"```lua", "local x = 1", "```"}, ""},
		{[]string{"```lua", "local x = 1"}, "```"},
		{[]string{"~~~", "tildes"}, "~~~"},
		{[]string{"````", "x", "```"}, "````"},                    // closer must match length
		{[]string{"```", "x", "```", "y", "```"}, "```"},          // re-open after close
		{[]string{"    ```", "indented four spaces is code"}, ""}, // >3 indent: not a fence
		{[]string{"  ```go", "up to 3 spaces ok"}, "```"},
		{[]string{"```", "x", "~~~", "y"}, "```"},  // tilde doesn't close backtick
		{[]string{"```", "```python", "x"}, "```"}, // info string after a closer keeps the fence open
		{[]string{"\t```", "x"}, ""},               // tab indent: not a fence (advances past 3 columns)
	}
	for _, c := range cases {
		if got := unclosedFence(c.lines); got != c.want {
			t.Errorf("unclosedFence(%q) = %q, want %q", c.lines, got, c.want)
		}
	}
}
