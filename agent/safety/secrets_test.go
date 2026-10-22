package safety

import (
	"os"
	"path/filepath"
	"testing"
)

func TestSecretLocationSurfacesStayTogether(t *testing.T) {
	for _, p := range secretLocations {
		if !IsSecretPath(p) {
			t.Errorf("path rule missed %s", p)
		}
		if got := MatchRules(SecretRevealRules(), "cat "+p+"/identity"); got != "reads a secret file" {
			t.Errorf("bash rule missed %s: %q", p, got)
		}
	}
	copyOfPaths := SecretPaths()
	copyOfPaths[0] = "/tmp"
	if SecretPaths()[0] == "/tmp" {
		t.Fatal("SecretPaths exposed mutable policy")
	}
}

func TestIsSecretPath(t *testing.T) {
	// a direct secret path (via ~ expansion) matches even when it does not exist
	if !IsSecretPath("~/.ssh/id_ed25519") {
		t.Error("~/.ssh/id_ed25519 should be a secret path")
	}
	// a normal file is not
	if IsSecretPath("/tmp/ok.txt") {
		t.Error("/tmp/ok.txt should not be a secret path")
	}
	// /run/agenix is itself a symlink to /run/agenix.d/<n>; both the literal
	// and resolved forms must match (see secretPaths comment).
	for _, p := range []string{
		"/run/agenix",
		"/run/agenix.d",
		"/run/agenix.d/184/secrets/x",
		"/etc/agenix/y",
	} {
		if !IsSecretPath(p) {
			t.Errorf("%s should be a secret path", p)
		}
	}
}

// TestIsSecretPathSymlink checks that a symlink into a secret directory is
// detected. It overrides secretPaths with a temp home so the test does not
// depend on ~/.ssh existing (the CI runner has none), which would leave the
// symlink dangling and unresolvable by EvalSymlinks.
func TestIsSecretPathSymlink(t *testing.T) {
	home := t.TempDir()
	ssh := filepath.Join(home, ".ssh")
	if err := os.Mkdir(ssh, 0o700); err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(ssh, "id_ed25519"), []byte("k"), 0o600); err != nil {
		t.Fatal(err)
	}

	old := secretPaths
	secretPaths = []string{ssh, "/etc/ssh", "/run/agenix", "/etc/agenix"}
	t.Cleanup(func() { secretPaths = old })

	link := filepath.Join(t.TempDir(), "link")
	if err := os.Symlink(ssh, link); err != nil {
		t.Skipf("symlink unavailable: %v", err)
	}
	if !IsSecretPath(filepath.Join(link, "id_ed25519")) {
		t.Fatal("symlinked secret path not detected")
	}
}

func TestSecretPathRule(t *testing.T) {
	rule := SecretPathRule("reads a secret path")
	if rule.Name != "reads a secret path" || rule.Match == nil || rule.Always {
		t.Fatalf("rule shape: %+v", rule)
	}
	if got := MatchRules([]Rule{rule}, "~/.ssh/id_ed25519"); got != "reads a secret path" {
		t.Fatalf("secret path: %q", got)
	}
	if got := MatchRules([]Rule{rule}, "/tmp/ok.txt"); got != "" {
		t.Fatalf("non-secret path: %q", got)
	}
	if got := MatchRules([]Rule{rule}, ""); got != "" {
		t.Fatalf("empty path: %q", got)
	}
}

// TestSecretRevealRules checks the bash guard rules for commands whose
// output is secret material: decryption, private-key generation/export, and
// reading secret files. Each case asserts which rule (if any) matches, via
// MatchRules over the full bash rule set.
func TestSecretRevealRules(t *testing.T) {
	rules := SecretRevealRules()
	cases := []struct {
		cmd  string
		want string // "" means no rule should match
	}{
		// age decrypt prints plaintext; encrypt is fine.
		{"age -d secret.age", "decrypts secret material"},
		{"age --decrypt secret.age", "decrypts secret material"},
		{"age -e -r age1xyz secret.txt", ""},
		{"age -r age1xyz -o out.age in.txt", ""},

		// gpg decrypt vs encrypt/export-public.
		{"gpg --decrypt file.gpg", "decrypts secret material"},
		{"gpg -d file.gpg", "decrypts secret material"},
		{"gpg2 --decrypt file.gpg", "decrypts secret material"},
		{"gpg --encrypt -r user file", ""},
		{"gpg --export", ""},

		// sops decrypt (bare, --, -d) and exec-*; encrypt is fine.
		{"sops decrypt secrets.yaml", "decrypts secret material"},
		{"sops -d secrets.yaml", "decrypts secret material"},
		{"sops exec-env secrets.yaml -- cmd", "decrypts secret material"},
		{"sops exec-file secrets.yaml /tmp/x", "decrypts secret material"},
		{"sops encrypt secrets.yaml", ""},

		// openssl symmetric decrypt vs encrypt; enc without -d is encrypt.
		{"openssl enc -d -aes-256-cbc -in x.enc", "decrypts secret material"},
		{"openssl enc -e -aes-256-cbc -in x", ""},

		// age-keygen prints a secret key; -y derives public recipients only.
		{"age-keygen", "reveals a secret key"},
		{"age-keygen -o key.txt", "reveals a secret key"},
		{"age-keygen -pq", "reveals a secret key"},
		{"age-keygen -y key.txt", ""},

		// gpg secret key export vs public export.
		{"gpg --export-secret-keys user", "reveals a secret key"},
		{"gpg --export-secret-subkeys user", "reveals a secret key"},
		{"gpg --export", ""},

		// openssl private-key subcommands print key material; req/x509 do not.
		{"openssl rsa -in key.pem", "reveals a secret key"},
		{"openssl ec -in key.pem -text", "reveals a secret key"},
		{"openssl pkey -in key.pem", "reveals a secret key"},
		{"openssl genrsa 2048", "reveals a secret key"},
		{"openssl req -new -x509 -key k.pem -out c.pem", ""},

		// reading secret files (home form, $HOME, absolute, system dirs).
		{"cat ~/.ssh/id_ed25519", "reads a secret file"},
		{"cat $HOME/.aws/credentials", "reads a secret file"},
		{"grep Host ~/.gnupg/gpg.conf", "reads a secret file"},
		{"cat /run/agenix/db/password", "reads a secret file"},
		{"head -5 /etc/ssh/ssh_host_ed25519_key", "reads a secret file"},
		// benign reads.
		{"cat /etc/passwd", ""},
		{"cat foo.txt", ""},
		{"echo ~/.ssh", ""}, // echo is not a reader
	}
	for _, c := range cases {
		got := MatchRules(rules, c.cmd)
		if got != c.want {
			t.Errorf("MatchRules(%q) = %q, want %q", c.cmd, got, c.want)
		}
	}
}
