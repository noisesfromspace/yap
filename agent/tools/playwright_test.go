package tools

import "testing"

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
