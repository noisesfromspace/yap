package safety

import "testing"

func TestMatchRules(t *testing.T) {
	rules := []Rule{
		Pattern("sudo", `(?i)\bsudo\b`),
		Pattern("recursive deletion", `(?i)\brm\s+-[a-z]*r`),
		{Name: "sends a request body", Match: func(s string) bool { return s != "" }},
	}
	for _, tc := range []struct{ text, want string }{
		{"echo hi", "sends a request body"}, // rules are ordered; the first match wins
		{"sudo ls", "sudo"},
		{"rm -rf /", "recursive deletion"},
		{"", ""},
	} {
		if got := MatchRules(rules, tc.text); got != tc.want {
			t.Errorf("MatchRules(%q) = %q, want %q", tc.text, got, tc.want)
		}
	}
}

func TestPatternPanicsOnBadExpression(t *testing.T) {
	defer func() {
		if recover() == nil {
			t.Fatal("Pattern with a bad expression should panic at init")
		}
	}()
	Pattern("broken", `(`)
}
