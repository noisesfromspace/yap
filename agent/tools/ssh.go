package tools

import (
	"context"
	"fmt"
	"net"
	"os"
	"os/user"
	"path/filepath"
	"strconv"
	"strings"
	"sync"
	"time"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/knownhosts"
)

type sshArgs struct {
	Host    string `json:"host" jsonschema:"description=SSH host (must be in known_hosts)"`
	Command string `json:"command,omitempty" jsonschema:"description=remote command to run"`
	User    string `json:"user,omitempty" jsonschema:"description=remote user (default local username)"`
	Port    int    `json:"port,omitempty" jsonschema:"description=SSH port (default 22)"`
	Timeout int    `json:"timeout,omitempty" jsonschema:"description=timeout in seconds (default 120)"`
	Close   bool   `json:"close,omitempty" jsonschema:"description=close the cached connection instead of running a command"`
}

var sshClients = struct {
	sync.Mutex
	clients map[string]*ssh.Client
}{clients: make(map[string]*ssh.Client)}

func init() {
	Register("ssh", "Run commands over a reused in-process SSH connection. Uses ~/.ssh/id_ed25519 and verifies ~/.ssh/known_hosts; unknown hosts are refused. close=true disconnects. Non-interactive; no agent or X11 forwarding.", func(a *sshArgs) (string, string, error) {
		result, err := runSSH(a)
		return result, "", err
	})
}

func runSSH(a *sshArgs) (string, error) {
	if a.Host == "" || strings.ContainsAny(a.Host, "/\\@:\n\r") {
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
	if strings.ContainsAny(name, "@\n\r") {
		return "", fmt.Errorf("invalid SSH user")
	}
	key := name + "@" + net.JoinHostPort(a.Host, strconv.Itoa(port))
	sshClients.Lock()
	defer sshClients.Unlock()
	client := sshClients.clients[key]
	if a.Close {
		if client != nil {
			client.Close()
			delete(sshClients.clients, key)
		}
		return "connection closed", nil
	}
	if strings.TrimSpace(a.Command) == "" {
		return "", fmt.Errorf("empty command")
	}
	timeout := 120 * time.Second
	if a.Timeout > 0 {
		timeout = time.Duration(a.Timeout) * time.Second
	}
	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()
	if client == nil {
		var err error
		client, err = dialSSH(ctx, a.Host, port, name)
		if err != nil {
			return "", err
		}
		sshClients.clients[key] = client
	}
	session, err := client.NewSession()
	if err != nil {
		client.Close()
		delete(sshClients.clients, key)
		client, err = dialSSH(ctx, a.Host, port, name)
		if err != nil {
			return "", err
		}
		sshClients.clients[key] = client
		session, err = client.NewSession()
		if err != nil {
			client.Close()
			delete(sshClients.clients, key)
			return "", err
		}
	}
	defer session.Close()
	var output headBuffer
	session.Stdout, session.Stderr = &output, &output
	done := make(chan error, 1)
	go func() { done <- session.Run(a.Command) }()
	select {
	case err = <-done:
	case <-ctx.Done():
		client.Close()
		delete(sshClients.clients, key)
		return "", fmt.Errorf("SSH command timed out after %s", timeout)
	}
	text := output.String()
	if output.Truncated() {
		text += "\n[output truncated at 50KB]"
	}
	if strings.TrimSpace(text) == "" {
		text = "(no output)"
	}
	if err != nil {
		if e, ok := err.(*ssh.ExitError); ok {
			return fmt.Sprintf("%s\n[exit code %d]", text, e.ExitStatus()), nil
		}
		client.Close()
		delete(sshClients.clients, key)
		return "", err
	}
	return text, nil
}

func dialSSH(ctx context.Context, host string, port int, name string) (*ssh.Client, error) {
	home, err := os.UserHomeDir()
	if err != nil {
		return nil, err
	}
	key, err := os.ReadFile(filepath.Join(home, ".ssh", "id_ed25519"))
	if err != nil {
		return nil, err
	}
	signer, err := ssh.ParsePrivateKey(key)
	if err != nil {
		return nil, err
	}
	verify, err := knownhosts.New(filepath.Join(home, ".ssh", "known_hosts"))
	if err != nil {
		return nil, err
	}
	addr := net.JoinHostPort(host, strconv.Itoa(port))
	conn, err := (&net.Dialer{}).DialContext(ctx, "tcp", addr)
	if err != nil {
		return nil, err
	}
	// Bound authentication/host-key exchange as well as the TCP dial.
	if deadline, ok := ctx.Deadline(); ok {
		conn.SetDeadline(deadline)
	}
	c, chans, reqs, err := ssh.NewClientConn(conn, addr, &ssh.ClientConfig{
		User: name, Auth: []ssh.AuthMethod{ssh.PublicKeys(signer)}, HostKeyCallback: verify,
	})
	if err != nil {
		conn.Close()
		return nil, err
	}
	conn.SetDeadline(time.Time{})
	return ssh.NewClient(c, chans, reqs), nil
}
