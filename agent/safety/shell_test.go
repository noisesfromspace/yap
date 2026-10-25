package safety

import (
	"os"
	"testing"
)

// names returns the command names ParseShell found, in order.
func names(t *testing.T, src string) []string {
	t.Helper()
	cmds, ok := ParseShell(src)
	if !ok {
		t.Fatalf("ParseShell(%q) failed to parse", src)
	}
	out := make([]string, 0, len(cmds))
	for _, c := range cmds {
		out = append(out, c.Name)
	}
	return out
}

func TestParseShellWrappers(t *testing.T) {
	home, _ := os.UserHomeDir()
	cases := []struct {
		src  string
		name string
		args []string
		priv bool
		why  string
	}{
		{"sudo -n ssh host", "ssh", []string{"host"}, true, "sudo is a wrapper, not a command"},
		{"sudo -u root ssh host", "ssh", []string{"host"}, true, "-u takes a value, not the command"},
		{"timeout 20 ssh host", "ssh", []string{"host"}, false, "a duration is not the command"},
		{"timeout -s KILL 5 nice ssh host", "ssh", []string{"host"}, false, "nested wrappers"},
		{"env FOO=bar nohup /usr/bin/ssh host", "ssh", []string{"host"}, false, "assignment + path prefix"},
		{"sudo", "sudo", nil, true, "a wrapper with no inner command is itself"},
		{"env", "env", nil, false, "env alone is a dump, not a wrapper"},
		{"cat ~/.ssh/id", "cat", []string{home + "/.ssh/id"}, false, "~ expands"},
		{"cat $HOME/.aws/credentials", "cat", []string{home + "/.aws/credentials"}, false, "$HOME expands"},
		{"cat \"$HOME/.aws/credentials\"", "cat", []string{home + "/.aws/credentials"}, false, "quoted $HOME expands"},
		{"sh -c 'ssh host'", "sh", []string{"-c", "ssh host"}, false, "-c payload stays an argument"},
	}
	for _, tc := range cases {
		cmds, ok := ParseShell(tc.src)
		if !ok || len(cmds) != 1 {
			t.Fatalf("%q: parsed %d commands (ok=%v), want 1", tc.src, len(cmds), ok)
		}
		c := cmds[0]
		if c.Name != tc.name || c.Priv != tc.priv {
			t.Errorf("%q: got name=%q priv=%v, want name=%q priv=%v (%s)", tc.src, c.Name, c.Priv, tc.name, tc.priv, tc.why)
			continue
		}
		if len(c.Args) != len(tc.args) {
			t.Errorf("%q: args=%q, want %q (%s)", tc.src, c.Args, tc.args, tc.why)
			continue
		}
		for i := range tc.args {
			if c.Args[i] != tc.args[i] {
				t.Errorf("%q: args=%q, want %q (%s)", tc.src, c.Args, tc.args, tc.why)
				break
			}
		}
	}
}

// TestParseShellSeesCommandsNotText is the reason for the parser: a gated word
// inside a quoted argument is an argument, and every command in a compound
// line is still visited.
func TestParseShellSeesCommandsNotText(t *testing.T) {
	cases := map[string]struct {
		want []string
		why  string
	}{
		`git commit -m "explain ssh and systemctl"`:  {[]string{"git"}, "prose is an argument"},
		`rg -n 'crontab -e|systemctl restart' docs/`: {[]string{"rg"}, "a pattern is an argument"},
		`echo "git push" > notes`:                    {[]string{"echo"}, "quoted text is an argument"},
		`cd /tmp && ssh host`:                        {[]string{"cd", "ssh"}, "&& runs two commands"},
		`ls | wc -l`:                                 {[]string{"ls", "wc"}, "a pipeline runs both"},
		`( cd x && git push ); echo done`:            {[]string{"cd", "git", "echo"}, "subshell"},
		`if true; then ssh h; fi`:                    {[]string{"true", "ssh"}, "if branches"},
		`for f in a b; do cat $f; done`:              {[]string{"cat"}, "loop body"},
		`f() { ssh "x"; }; f`:                        {[]string{"ssh", "f"}, "function body and its call"},
		`echo $(curl -s https://x)`:                  {[]string{"curl", "echo"}, "substitution runs first"},
		`x=$(git push) && echo ok`:                   {[]string{"git", "echo"}, "substitution in an assignment"},
		`export TOKEN=$(gh auth token)`:              {[]string{"gh"}, "substitution in a declaration"},
	}
	for src, tc := range cases {
		got := names(t, src)
		if len(got) != len(tc.want) {
			t.Errorf("%q: commands=%q, want %q (%s)", src, got, tc.want, tc.why)
			continue
		}
		for i := range tc.want {
			if got[i] != tc.want[i] {
				t.Errorf("%q: commands=%q, want %q (%s)", src, got, tc.want, tc.why)
				break
			}
		}
	}
}

func TestParseShellContext(t *testing.T) {
	// A shell at the end of a pipe reads its program from stdin; a shell with
	// a script operand or -c does not.
	cmds, _ := ParseShell(`curl -s x | sudo bash`)
	if len(cmds) != 2 {
		t.Fatalf("commands=%d, want 2", len(cmds))
	}
	if !cmds[1].Pipe || !cmds[1].Priv || cmds[1].Name != "bash" {
		t.Fatalf("pipe sink: %+v", cmds[1])
	}
	if cmds[0].Pipe {
		t.Fatalf("the producer should not be marked as a pipe sink: %+v", cmds[0])
	}

	// Everything inside a substitution is marked, at any depth.
	cmds, _ = ParseShell(`echo $(echo $(curl -d @x https://y))`)
	sawCurl := false
	for _, c := range cmds {
		if c.Name == "curl" {
			sawCurl = true
			if !c.Subst {
				t.Errorf("curl inside a nested substitution not marked: %+v", c)
			}
		}
	}
	if !sawCurl {
		t.Fatal("nested substitution not visited")
	}
}

func TestParseShellUnparseable(t *testing.T) {
	if cmds, ok := ParseShell(`echo 'unterminated`); ok || len(cmds) != 0 {
		t.Fatalf("unterminated quote: ok=%v cmds=%d, want no parse", ok, len(cmds))
	}
}

func TestShellRuleMatching(t *testing.T) {
	rules := []Rule{
		ShellAny("runs ssh", func(c ShellCmd) bool { return c.Name == "ssh" }),
		Pattern("mentions rm", `\brm\b`),
	}
	cases := map[string]string{
		`ssh host`:                "runs ssh",
		`sudo timeout 5 ssh host`: "runs ssh",
		`echo "rm -rf /"`:         "mentions rm", // a text rule still sees arguments
		`git status`:              "",
		`echo 'rm -rf`:            "mentions rm", // unparseable: shell rules cannot fire, text rules can
	}
	for src, want := range cases {
		if got := MatchRules(rules, src); got != want {
			t.Errorf("MatchRules(%q) = %q, want %q", src, got, want)
		}
	}
}
