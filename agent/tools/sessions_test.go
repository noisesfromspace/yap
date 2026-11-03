package tools

import (
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/utils"
)

func writeSession(t *testing.T, root, rel, body string) string {
	t.Helper()
	sdir := filepath.Join(root, rel)
	if err := os.MkdirAll(sdir, 0o755); err != nil {
		t.Fatal(err)
	}
	p := filepath.Join(sdir, "session.md")
	if err := os.WriteFile(p, []byte(body), 0o644); err != nil {
		t.Fatal(err)
	}
	return p
}

func TestSessionsList(t *testing.T) {
	dir := t.TempDir()
	utils.SetSessionsRoot(dir)
	defer utils.SetSessionsRoot("")

	writeSession(t, dir, "proj/26-10/01-12.00.00",
		"---\ndescription: Fix the winbar\ncreated_cwd: /opt/code/yap\nmodel: deepseek-flash\nturns: 3\n---\n\n# @system\nhi\n# @user\nplease\n# @assistant\ndone\n")
	writeSession(t, dir, "proj/26-10/02-12.00.00",
		"---\ndescription: Session picker labels\n---\n\n# @user\nx\n")

	r, _, err := run(t, "sessions", `{"action":"list"}`)
	if err != nil {
		t.Fatalf("list: %v", err)
	}
	if !strings.Contains(r, "Fix the winbar") || !strings.Contains(r, "Session picker labels") {
		t.Fatalf("list missing descriptions: %q", r)
	}
	if !strings.Contains(r, "session.md") || !strings.Contains(r, "cwd=/opt/code/yap") {
		t.Fatalf("list missing path/cwd: %q", r)
	}

	// scope to one project excludes the other
	r, _, err = run(t, "sessions", `{"action":"list","path":"`+dir+`/proj"}`)
	if err != nil {
		t.Fatalf("scoped list: %v", err)
	}
	if !strings.Contains(r, "Fix the winbar") || !strings.Contains(r, "Session picker labels") {
		t.Fatalf("scoped list should still contain both sessions: %q", r)
	}
}

func TestSessionsSearch(t *testing.T) {
	if _, err := exec.LookPath("rg"); err != nil {
		t.Skip("rg not available")
	}
	dir := t.TempDir()
	utils.SetSessionsRoot(dir)
	defer utils.SetSessionsRoot("")

	writeSession(t, dir, "proj/26-10/01-12.00.00", "---\ndescription: x\n---\n\n# @user\nneedle here\n")
	// assets/ holds a copy of another session and must be excluded.
	writeSession(t, dir, "proj/26-10/01-12.00.00/assets/backup", "---\n---\n\nneedle copy\n")

	r, _, err := run(t, "sessions", `{"action":"search","pattern":"needle"}`)
	if err != nil {
		t.Fatalf("search: %v", err)
	}
	if !strings.Contains(r, "needle here") {
		t.Fatalf("search missing match: %q", r)
	}
	if strings.Contains(r, "needle copy") {
		t.Fatalf("search leaked assets copy: %q", r)
	}
	if _, _, err := run(t, "sessions", `{"action":"search","pattern":"   "}`); err == nil || !strings.Contains(err.Error(), "empty pattern") {
		t.Fatalf("blank pattern: %v", err)
	}
}

func TestSessionsRead(t *testing.T) {
	dir := t.TempDir()
	utils.SetSessionsRoot(dir)
	defer utils.SetSessionsRoot("")

	p := writeSession(t, dir, "proj/26-10/01-12.00.00",
		"---\ndescription: Winbar fix\ncreated_cwd: /opt/code/yap\nturns: 1\n---\n\n# @user\nhello world\n# @assistant\n<!-- yap:thinking\nsecret thinking\n-->\n\nFixed it.\n<!-- yap:tool {\"id\":\"c1\",\"name\":\"edit\",\"arguments\":{}} -->\nok\n<!-- /yap:tool -->\n")

	r, _, err := run(t, "sessions", `{"action":"read","path":"`+p+`"}`)
	if err != nil {
		t.Fatalf("read: %v", err)
	}
	for _, want := range []string{"Winbar fix", "hello world", "Fixed it.", "@user", "@assistant", "[tool: edit]"} {
		if !strings.Contains(r, want) {
			t.Fatalf("read missing %q: %q", want, r)
		}
	}
	if strings.Contains(r, "secret thinking") {
		t.Fatalf("thinking leaked into read: %q", r)
	}

	// reading a directory resolves its transcript
	r, _, err = run(t, "sessions", `{"action":"read","path":"`+filepath.Dir(p)+`"}`)
	if err != nil || !strings.Contains(r, "hello world") {
		t.Fatalf("read via dir: %q %v", r, err)
	}

	// paging: start/count bounds the prose (the outline still lists every message)
	r, _, err = run(t, "sessions", `{"action":"read","path":"`+p+`","start":2,"count":1}`)
	if err != nil {
		t.Fatalf("paged read: %v", err)
	}
	if strings.Contains(r, "### [1] @user") {
		t.Fatalf("paged read leaked message 1 prose: %q", r)
	}
	if !strings.Contains(r, "### [2] @assistant") {
		t.Fatalf("paged read missing message 2 prose: %q", r)
	}
}

func TestSessionsErrors(t *testing.T) {
	utils.SetSessionsRoot("")
	if _, _, err := run(t, "sessions", `{"action":"list"}`); err == nil || !strings.Contains(err.Error(), "sessions root") {
		t.Fatalf("no root: %v", err)
	}
	if _, _, err := run(t, "sessions", `{"action":"bogus"}`); err == nil || !strings.Contains(err.Error(), "unknown action") {
		t.Fatalf("bogus action: %v", err)
	}
	if _, _, err := run(t, "sessions", `{"action":"read"}`); err == nil || !strings.Contains(err.Error(), "needs a path") {
		t.Fatalf("read without path: %v", err)
	}
}
