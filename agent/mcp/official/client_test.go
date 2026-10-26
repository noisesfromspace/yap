package official

import "testing"

func TestResolveHeader(t *testing.T) {
	t.Setenv("CENSYS_API_KEY", "secret-token")
	t.Setenv("EXA_API_KEY", "exa-secret")

	cases := []struct {
		spec    string
		want    string
		wantErr bool
	}{
		{spec: "EXA_API_KEY", want: "exa-secret"},
		{spec: "CENSYS_API_KEY", want: "secret-token"},
		{spec: "Bearer CENSYS_API_KEY", want: "Bearer secret-token"},
		{spec: "Basic CENSYS_API_KEY", want: "Basic secret-token"},
		{spec: "MISSING_VAR", wantErr: true},
		{spec: "Bearer MISSING_VAR", wantErr: true},
	}
	for _, c := range cases {
		got, err := resolveHeader(c.spec)
		if c.wantErr {
			if err == nil {
				t.Errorf("resolveHeader(%q) = %q, want error", c.spec, got)
			}
			continue
		}
		if err != nil {
			t.Errorf("resolveHeader(%q): %v", c.spec, err)
			continue
		}
		if got != c.want {
			t.Errorf("resolveHeader(%q) = %q, want %q", c.spec, got, c.want)
		}
	}
}
