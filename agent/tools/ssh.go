package tools

import (
	"bytes"
	"context"
	"crypto/sha256"
	"fmt"
	"net"
	"os"
	"os/exec"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"syscall"
	"time"

	"boers.email/yap/agent/utils"
)

type sshArgs struct {
	Host    string `json:"host" jsonschema:"description=SSH host (must be named in /etc/ssh/ssh_known_hosts)"`
	Command string `json:"command,omitempty" jsonschema:"description=remote command to run"`
	User    string `json:"user,omitempty" jsonschema:"description=remote user (default local username)"`
	Port    int    `json:"port,omitempty" jsonschema:"description=SSH port (default 22)"`
	Timeout int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Close   bool   `json:"close,omitempty" jsonschema:"description=close the cached connection instead of running a command"`
}

var systemKnownHosts = "/etc/ssh/ssh_known_hosts"
var sshBinary = "ssh"

// The directory is private to this backend process. A control socket grants
// the same authority as an authenticated connection to local processes that
// can access it; never place it in a shared directory or use ControlPersist.
var sshMasters = struct {
	sync.Mutex
	dir     string
	clients map[string]*sshMaster
}{clients: make(map[string]*sshMaster)}

type sshMaster struct {
	cmd    *exec.Cmd
	done   chan error
	socket string
	stderr bytes.Buffer
}

func init() {
	Register("ssh", "Run commands via OpenSSH using a reused ControlMaster owned by the Yap backend. Only hosts in /etc/ssh/ssh_known_hosts are trusted. Uses OpenSSH default identities and the local ssh-agent (including FIDO keys); ~/.ssh/config is not loaded. close=true disconnects. No agent/X11 forwarding. Non-interactive; no password or PIN prompt.", func(a *sshArgs) (string, string, error) {
		result, err := runSSH(a)
		return result, "", err
	})
}

// Do not load ~/.ssh/config: aliases, ProxyCommand, HostKeyAlias, and
// user-specified host key files could bypass the system host allowlist.
func sshOptions() []string {
	return []string{"-F", "/dev/null", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "GlobalKnownHostsFile=" + systemKnownHosts, "-o", "UserKnownHostsFile=/dev/null", "-o", "CheckHostIP=no", "-o", "UpdateHostKeys=no", "-o", "ForwardAgent=no", "-o", "ClearAllForwardings=yes"}
}

func sshTarget(a *sshArgs, name string, port int) []string {
	return []string{"-l", name, "-p", strconv.Itoa(port), "--", a.Host}
}

func runSSH(a *sshArgs) (string, error) {
	if a.Host == "" || strings.HasPrefix(a.Host, "-") || strings.ContainsAny(a.Host, "/\\@:\n\r ") {
		return "", fmt.Errorf("invalid SSH host")
	}
	port := a.Port
	if port == 0 {
		port = 22
	}
	if port < 1 || port > 65535 {
		return "", fmt.Errorf("invalid SSH port")
	}
	name := a.User
	if name == "" {
		u, err := user.Current()
		if err != nil {
			return "", err
		}
		name = u.Username
	}
	if name == "" || strings.HasPrefix(name, "-") || strings.ContainsAny(name, "@\n\r ") {
		return "", fmt.Errorf("invalid SSH user")
	}
	key := name + "@" + net.JoinHostPort(a.Host, strconv.Itoa(port))
	sshMasters.Lock()
	defer sshMasters.Unlock()
	if a.Close {
		if m := sshMasters.clients[key]; m != nil {
			stopMaster(m)
			delete(sshMasters.clients, key)
		}
		removeSSHDirIfEmpty()
		return "connection closed", nil
	}
	if strings.TrimSpace(a.Command) == "" {
		return "", fmt.Errorf("empty command")
	}
	if utils.IsDangerousCommand(a.Command) {
		ok, err := utils.RequestApproval(fmt.Sprintf("ssh %s@%s -- %s", name, a.Host, a.Command))
		if err != nil {
			return "", fmt.Errorf("SSH command requires approval: %w", err)
		}
		if !ok {
			return "", fmt.Errorf("SSH command rejected by user")
		}
	}
	timeout := 120 * time.Second
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	// -F /dev/null makes OpenSSH check only the requested name. A known IP
	// or an entry in the user's known_hosts cannot authorize a different name.
	host := a.Host
	if port != 22 {
		host = fmt.Sprintf("[%s]:%d", host, port)
	}
	check := exec.CommandContext(ctx, "ssh-keygen", "-F", host, "-f", systemKnownHosts)
	if err := check.Run(); err != nil {
		return "", fmt.Errorf("SSH host %s is not in system known hosts: %w", a.Host, err)
	}
	m := sshMasters.clients[key]
	if m != nil && !masterAlive(ctx, m, a, name, port) {
		stopMaster(m)
		delete(sshMasters.clients, key)
		m = nil
	}
	if m == nil {
		var err error
		m, err = startMaster(ctx, a, name, port, key)
		if err != nil {
			return "", err
		}
		sshMasters.clients[key] = m
	}
	// Each command is a separate SSH session over the foreground master.
	// A missing master can cause ssh to dial afresh; evict it on any failure.
	args := append(sshOptions(), "-S", m.socket, "-o", "ControlMaster=auto", "-o", "ControlPersist=no")
	args = append(args, sshTarget(a, name, port)...)
	args = append(args, a.Command)
	cmd := exec.CommandContext(ctx, sshBinary, args...)
	var output headBuffer
	cmd.Stdout, cmd.Stderr = &output, &output
	err := cmd.Run()
	if ctx.Err() != nil {
		stopMaster(m)
		delete(sshMasters.clients, key)
		removeSSHDirIfEmpty()
		return "", fmt.Errorf("SSH command timed out after %s: %w", timeout, ctx.Err())
	}
	text := output.String()
	if output.Truncated() {
		text += "\n[output truncated at 50KB]"
	}
	if strings.TrimSpace(text) == "" {
		text = "(no output)"
	}
	if err != nil {
		if ee, ok := err.(*exec.ExitError); ok {
			// OpenSSH uses 255 for connection errors (remote 255 is ambiguous).
			if ee.ExitCode() != 255 {
				return fmt.Sprintf("%s\n[exit code %d]", text, ee.ExitCode()), nil
			}
		}
		stopMaster(m)
		delete(sshMasters.clients, key)
		removeSSHDirIfEmpty()
		return "", fmt.Errorf("SSH: %s: %w", text, err)
	}
	return text, nil
}

func masterAlive(ctx context.Context, m *sshMaster, a *sshArgs, name string, port int) bool {
	select {
	case <-m.done:
		return false
	default:
	}
	probeCtx, cancel := context.WithTimeout(ctx, time.Second)
	defer cancel()
	args := append(sshOptions(), "-S", m.socket, "-O", "check")
	args = append(args, sshTarget(a, name, port)...)
	return exec.CommandContext(probeCtx, sshBinary, args...).Run() == nil
}

func startMaster(ctx context.Context, a *sshArgs, name string, port int, key string) (*sshMaster, error) {
	if sshMasters.dir == "" {
		dir, err := os.MkdirTemp("", "yap-ssh-")
		if err != nil {
			return nil, err
		}
		sshMasters.dir = dir // MkdirTemp uses mode 0700
	}
	hash := sha256.Sum256([]byte(key))
	m := &sshMaster{socket: filepath.Join(sshMasters.dir, fmt.Sprintf("%x", hash[:12])), done: make(chan error, 1)}
	args := append(sshOptions(), "-S", m.socket, "-M", "-N", "-o", "ControlPersist=no")
	args = append(args, sshTarget(a, name, port)...)
	m.cmd = exec.Command(sshBinary, args...)
	m.cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
	m.cmd.Stdin = nil
	m.cmd.Stderr = &m.stderr
	if err := m.cmd.Start(); err != nil {
		removeSSHDirIfEmpty()
		return nil, err
	}
	utils.Track(m.cmd.Process.Pid)
	go func() { err := m.cmd.Wait(); utils.Untrack(m.cmd.Process.Pid); m.done <- err; close(m.done) }()
	ticker := time.NewTicker(100 * time.Millisecond)
	defer ticker.Stop()
	for {
		if masterAlive(ctx, m, a, name, port) {
			return m, nil
		}
		select {
		case err := <-m.done:
			removeSSHDirIfEmpty()
			return nil, fmt.Errorf("SSH master exited: %w: %s", err, m.stderr.String())
		case <-ctx.Done():
			stopMaster(m)
			removeSSHDirIfEmpty()
			return nil, fmt.Errorf("SSH master timed out: %w", ctx.Err())
		case <-ticker.C:
		}
	}
}

func stopMaster(m *sshMaster) {
	// Graceful mux shutdown when possible; always reap the foreground child.
	ctx, cancel := context.WithTimeout(context.Background(), time.Second)
	defer cancel()
	exec.CommandContext(ctx, sshBinary, "-S", m.socket, "-O", "exit", "--", "localhost").Run()
	select {
	case <-m.done:
	case <-time.After(time.Second):
		syscall.Kill(-m.cmd.Process.Pid, syscall.SIGKILL)
		<-m.done
	}
	os.Remove(m.socket)
}

func removeSSHDirIfEmpty() {
	if sshMasters.dir != "" && len(sshMasters.clients) == 0 {
		os.Remove(sshMasters.dir)
		sshMasters.dir = ""
	}
}

// CloseSSH is called on normal backend exit and on :YapStop/SIGTERM.
func CloseSSH() {
	sshMasters.Lock()
	defer sshMasters.Unlock()
	for key, m := range sshMasters.clients {
		stopMaster(m)
		delete(sshMasters.clients, key)
	}
	removeSSHDirIfEmpty()
}
