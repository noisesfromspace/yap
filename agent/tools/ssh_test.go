package tools

import (
	"encoding/json"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/wire"
)

// The fake executable models OpenSSH's foreground master and mux commands;
// these tests check ownership, reuse, options, and shutdown without hardware.
func TestSSHControlMasterLifecycle(t *testing.T) {
	dir := t.TempDir()
	shell, err := exec.LookPath("sh")
	if err != nil {
		t.Fatal(err)
	}
	script := filepath.Join(dir, "ssh")
	log := filepath.Join(dir, "calls")
	source := `printf '%s\n' "$*" >> "$SSH_TEST_LOG"
case " $* " in
 *" -O check "*) test -e "$SSH_TEST_SOCKET" ;;
 *" -O exit "*) rm -f "$SSH_TEST_SOCKET"; exit 0 ;;
 *" -M -N "*) touch "$SSH_TEST_SOCKET"; trap 'rm -f "$SSH_TEST_SOCKET"; exit 0' TERM INT; while test -e "$SSH_TEST_SOCKET"; do sleep 0.1; done ;;
 *) echo remote-output ;;
esac
`
	if err := os.WriteFile(script, []byte("#!"+shell+"\n"+source), 0700); err != nil {
		t.Fatal(err)
	}
	known := filepath.Join(dir, "known")
	if err := os.WriteFile(known, []byte("example.test ssh-ed25519 AAAA\n"), 0600); err != nil {
		t.Fatal(err)
	}
	prev, prevBinary := systemKnownHosts, sshBinary
	systemKnownHosts, sshBinary = known, script
	t.Cleanup(func() { CloseSSH(); systemKnownHosts, sshBinary = prev, prevBinary })
	approvalIDs := make(chan string, 10)
	oldWriter := wire.SetFrameWriter(approvalIDWriter{ids: approvalIDs})
	oldReplies := wire.ApprovalReplies
	replies := make(chan wire.ApprovalReply)
	wire.ApprovalReplies = replies
	go func() {
		for id := range approvalIDs {
			replies <- wire.ApprovalReply{ID: id, Approved: true}
		}
	}()
	t.Cleanup(func() {
		wire.SetFrameWriter(oldWriter)
		close(approvalIDs)
		wire.ApprovalReplies = oldReplies
	})
	t.Setenv("SSH_TEST_LOG", log)
	// The fake uses the same socket name that startMaster computes.
	a := &sshArgs{Host: "example.test", User: "tester", Command: "first", Timeout: 3}
	// ssh-keygen -F requires a valid entry; use a dedicated fake for lookup.
	keygen := filepath.Join(dir, "ssh-keygen")
	if err := os.WriteFile(keygen, []byte("#!"+shell+"\ntest \"$2\" = example.test\n"), 0700); err != nil {
		t.Fatal(err)
	}
	t.Setenv("PATH", dir+":"+os.Getenv("PATH"))
	// For the fake master, precompute the socket from its arguments instead
	// using a helper script that extracts the -S option.
	source = strings.ReplaceAll(source, `"$SSH_TEST_SOCKET"`, `"$(printf '%s\n' "$*" | sed -n 's/.* -S \([^ ]*\).*/\1/p')"`)
	if err := os.WriteFile(script, []byte("#!"+shell+"\n"+source), 0700); err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []string{"first", "second"} {
		a.Command = cmd
		out, err := runSSH(a)
		if err != nil || out != "remote-output\n" {
			t.Fatalf("%s: %q %v", cmd, out, err)
		}
	}
	data, err := os.ReadFile(log)
	if err != nil {
		t.Fatal(err)
	}
	if strings.Count(string(data), " -M -N ") != 1 {
		t.Fatalf("expected one master: %s", data)
	}
	if !strings.Contains(string(data), "GlobalKnownHostsFile="+known) || !strings.Contains(string(data), "-F /dev/null") {
		t.Fatalf("missing trust options: %s", data)
	}
	socketDir := sshMasters.dir
	st, err := os.Stat(socketDir)
	if err != nil || st.Mode().Perm() != 0700 {
		t.Fatalf("socket dir mode: %v %v", st, err)
	}
	a.Close = true
	if _, err := runSSH(a); err != nil {
		t.Fatal(err)
	}
	if _, err := os.Stat(socketDir); !os.IsNotExist(err) {
		t.Fatalf("socket dir remains: %v", err)
	}
	a.Close = false
	if _, err := runSSH(a); err != nil {
		t.Fatal(err)
	}
	CloseSSH()
	if sshMasters.dir != "" || len(sshMasters.clients) != 0 {
		t.Fatal("backend exit left master")
	}
	data, _ = os.ReadFile(log)
	if strings.Count(string(data), " -M -N ") != 2 {
		t.Fatalf("expected redial after close: %s", data)
	}
	tool, ok := Get("ssh")
	if !ok {
		t.Fatal("tool not registered")
	}
	raw, _ := json.Marshal(map[string]any{"host": "-unsafe", "command": "hi"})
	if _, _, err := tool.Run(raw); err == nil {
		t.Fatal("option-like host accepted")
	}
}
