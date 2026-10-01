package utils

import "testing"

func TestResultFence(t *testing.T) {
	cases := []struct {
		name, args string
		wantLang   string
		wantOK     bool
	}{
		{"read", `{"path":"/tmp/x.py"}`, "python", true},
		{"read", `{"path":"/tmp/x.yaml"}`, "yaml", true},
		{"read", `{"path":"/tmp/x.unknown"}`, "", true}, // unrecognized ext: plain fence
		{"fetch", `{"url":"http://x"}`, "html", true},
		{"bash", `{"command":"ls"}`, "", true},
		{"ls", `{"path":"/tmp"}`, "", true},
		{"search", `{"pattern":"x"}`, "", true},
		{"glob", `{"pattern":"*.go"}`, "", true},
		{"write", `{"path":"/tmp/x","content":"y"}`, "", false},
		{"edit", `{"path":"/tmp/x","edits":[]}`, "", false},
	}
	for _, c := range cases {
		lang, ok := ResultFence(c.name, c.args)
		if lang != c.wantLang || ok != c.wantOK {
			t.Errorf("ResultFence(%s, %s) = (%q, %v), want (%q, %v)",
				c.name, c.args, lang, ok, c.wantLang, c.wantOK)
		}
	}
}
