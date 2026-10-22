package tools

import (
	"reflect"
	"testing"
)

func TestShellWordsCurrentQuoting(t *testing.T) {
	cases := []struct {
		input string
		want  []string
	}{
		{`fill ref "hello world"`, []string{"fill", "ref", "hello world"}},
		{`fill ref 'two words'`, []string{"fill", "ref", "two words"}},
		{`fill ref ""`, []string{"fill", "ref", ""}},
		{`fill ref "unfinished value`, []string{"fill", "ref", "unfinished value"}}, // unmatched quotes are tolerated
		{`fill ref abc"def ghi"`, []string{"fill", "ref", "abcdef ghi"}},
	}
	for _, tc := range cases {
		if got := shellWords(tc.input); !reflect.DeepEqual(got, tc.want) {
			t.Errorf("shellWords(%q) = %q, want %q", tc.input, got, tc.want)
		}
	}
}

func TestValidateSession(t *testing.T) {
	for _, s := range []string{"yap", "yap-2", "session_1", "a.b", "profile-2.x"} {
		if err := validateSession(s); err != nil {
			t.Errorf("validateSession(%q) = %v, want nil", s, err)
		}
	}
	for _, s := range []string{"../.ssh", "../../.ssh", "/etc/passwd", "..", ".", ".ssh", "a/b", `a\b`, "a b", "-x", "a:b", "a/../b"} {
		if err := validateSession(s); err == nil {
			t.Errorf("validateSession(%q) = nil, want error", s)
		}
	}
}
