package tools

import (
	"crypto/ed25519"
	"crypto/rand"
	"crypto/rsa"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/pem"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"

	"golang.org/x/crypto/ssh"
	"golang.org/x/crypto/ssh/agent"
)

func TestSSHVerifyReuseClose(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	dir := filepath.Join(home, ".ssh")
	if err := os.Mkdir(dir, 0700); err != nil {
		t.Fatal(err)
	}
	private, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(filepath.Join(dir, "id_ed25519"), pem.EncodeToMemory(&pem.Block{Type: "RSA PRIVATE KEY", Bytes: x509.MarshalPKCS1PrivateKey(private)}), 0600); err != nil {
		t.Fatal(err)
	}
	hostKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	var connections atomic.Int32
	config := &ssh.ServerConfig{NoClientAuth: true}
	config.AddHostKey(signer)
	go func() {
		for {
			conn, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				server, chans, reqs, err := ssh.NewServerConn(conn, config)
				if err != nil {
					conn.Close()
					return
				}
				connections.Add(1)
				go ssh.DiscardRequests(reqs)
				for ch := range chans {
					if ch.ChannelType() != "session" {
						ch.Reject(ssh.UnknownChannelType, "not session")
						continue
					}
					channel, requests, err := ch.Accept()
					if err != nil {
						continue
					}
					go func() {
						defer channel.Close()
						for req := range requests {
							if req.Type != "exec" {
								req.Reply(false, nil)
								continue
							}
							cmd := string(req.Payload[4:])
							req.Reply(true, nil)
							fmt.Fprint(channel, cmd)
							code := make([]byte, 4)
							if cmd == "fail" {
								binary.BigEndian.PutUint32(code, 7)
							}
							channel.SendRequest("exit-status", false, code)
							return
						}
					}()
				}
				server.Close()
			}()
		}
	}()
	host, portString, _ := net.SplitHostPort(listener.Addr().String())
	var port int
	fmt.Sscan(portString, &port)
	args := &sshArgs{Host: host, Port: port, User: "test", Command: "first", Timeout: 3}
	known := filepath.Join(home, "system_known_hosts")
	previous := systemKnownHosts
	systemKnownHosts = known
	t.Cleanup(func() { systemKnownHosts = previous })
	// A user known_hosts entry cannot authorize a host absent from the system list.
	userEntry := fmt.Sprintf("[localhost]:%d %s %s\n", port, signer.PublicKey().Type(), base64.StdEncoding.EncodeToString(signer.PublicKey().Marshal()))
	if err := os.WriteFile(filepath.Join(dir, "known_hosts"), []byte(userEntry), 0600); err != nil {
		t.Fatal(err)
	}
	os.WriteFile(known, []byte(""), 0600)
	if _, err := runSSH(args); err == nil || !strings.Contains(err.Error(), "knownhosts") && !strings.Contains(err.Error(), "known host") {
		t.Fatalf("untrusted host accepted: %v", err)
	}
	line := fmt.Sprintf("[%s]:%d %s %s\n", host, port, signer.PublicKey().Type(), base64.StdEncoding.EncodeToString(signer.PublicKey().Marshal()))
	if err := os.WriteFile(known, []byte(line), 0600); err != nil {
		t.Fatal(err)
	}
	args.Host = "localhost" // Only the connected IP is known to the system.
	if _, err := runSSH(args); err == nil || !strings.Contains(err.Error(), "unknown") {
		t.Fatalf("unlisted hostname accepted via IP: %v", err)
	}
	// The hostname itself must be explicitly listed by NixOS.
	knownHost := fmt.Sprintf("[localhost]:%d %s %s\n", port, signer.PublicKey().Type(), base64.StdEncoding.EncodeToString(signer.PublicKey().Marshal()))
	if err := os.WriteFile(known, []byte(line+knownHost), 0600); err != nil {
		t.Fatal(err)
	}
	// A conflicting hostname record must not fall back to the correct IP.
	other, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	wrong, err := ssh.NewSignerFromKey(other)
	if err != nil {
		t.Fatal(err)
	}
	mismatch := fmt.Sprintf("[localhost]:%d %s %s\n", port, wrong.PublicKey().Type(), base64.StdEncoding.EncodeToString(wrong.PublicKey().Marshal()))
	if err := os.WriteFile(known, []byte(line+mismatch), 0600); err != nil {
		t.Fatal(err)
	}
	args.Close = true
	if _, err := runSSH(args); err != nil {
		t.Fatal(err)
	}
	args.Close = false
	if _, err := runSSH(args); err == nil || !strings.Contains(err.Error(), "mismatch") {
		t.Fatalf("hostname mismatch bypassed with IP fallback: %v", err)
	}
	if err := os.WriteFile(known, []byte(line+knownHost), 0600); err != nil {
		t.Fatal(err)
	}
	for _, cmd := range []string{"first", "second", "fail"} {
		args.Command = cmd
		text, err := runSSH(args)
		if err != nil {
			t.Fatal(err)
		}
		if !strings.Contains(text, cmd) {
			t.Fatalf("missing output: %q", text)
		}
		if cmd == "fail" && !strings.Contains(text, "[exit code 7]") {
			t.Fatalf("missing exit code: %q", text)
		}
	}
	if got := connections.Load(); got != 1 {
		t.Fatalf("expected one authenticated connection, got %d", got)
	}
	args.Close = true
	if _, err := runSSH(args); err != nil {
		t.Fatal(err)
	}
	args.Close = false
	args.Command = "again"
	if _, err := runSSH(args); err != nil {
		t.Fatal(err)
	}
	if got := connections.Load(); got != 2 {
		t.Fatalf("close did not reconnect: %d", got)
	}
}

func TestSSHAgentIdentity(t *testing.T) {
	home := t.TempDir()
	t.Setenv("HOME", home)
	if err := os.Mkdir(filepath.Join(home, ".ssh"), 0700); err != nil {
		t.Fatal(err)
	}
	_, private, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	signer, err := ssh.NewSignerFromKey(private)
	if err != nil {
		t.Fatal(err)
	}
	keys := agent.NewKeyring()
	if err := keys.Add(agent.AddedKey{PrivateKey: private}); err != nil {
		t.Fatal(err)
	}
	socket := filepath.Join(home, "agent.sock")
	agentListener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer agentListener.Close()
	t.Setenv("SSH_AUTH_SOCK", socket)
	go func() {
		for {
			c, err := agentListener.Accept()
			if err != nil {
				return
			}
			go func() { defer c.Close(); agent.ServeAgent(keys, c) }()
		}
	}()
	hostKey, err := rsa.GenerateKey(rand.Reader, 2048)
	if err != nil {
		t.Fatal(err)
	}
	hostSigner, err := ssh.NewSignerFromKey(hostKey)
	if err != nil {
		t.Fatal(err)
	}
	config := &ssh.ServerConfig{PublicKeyCallback: func(_ ssh.ConnMetadata, key ssh.PublicKey) (*ssh.Permissions, error) {
		if string(key.Marshal()) != string(signer.PublicKey().Marshal()) {
			return nil, fmt.Errorf("wrong identity")
		}
		return nil, nil
	}}
	config.AddHostKey(hostSigner)
	listener, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	go func() {
		for {
			c, err := listener.Accept()
			if err != nil {
				return
			}
			go func() {
				server, chans, reqs, err := ssh.NewServerConn(c, config)
				if err != nil {
					c.Close()
					return
				}
				go ssh.DiscardRequests(reqs)
				for ch := range chans {
					channel, requests, err := ch.Accept()
					if err != nil {
						continue
					}
					go func() {
						defer channel.Close()
						for req := range requests {
							if req.Type == "exec" {
								req.Reply(true, nil)
								fmt.Fprint(channel, "agent authenticated")
								channel.SendRequest("exit-status", false, make([]byte, 4))
								return
							}
							req.Reply(false, nil)
						}
					}()
				}
				server.Close()
			}()
		}
	}()
	host, portString, _ := net.SplitHostPort(listener.Addr().String())
	var port int
	fmt.Sscan(portString, &port)
	known := fmt.Sprintf("[%s]:%d %s %s\n", host, port, hostSigner.PublicKey().Type(), base64.StdEncoding.EncodeToString(hostSigner.PublicKey().Marshal()))
	knownPath := filepath.Join(home, "system_known_hosts")
	previous := systemKnownHosts
	systemKnownHosts = knownPath
	t.Cleanup(func() { systemKnownHosts = previous })
	if err := os.WriteFile(knownPath, []byte(known), 0600); err != nil {
		t.Fatal(err)
	}
	result, err := runSSH(&sshArgs{Host: host, Port: port, User: "test", Command: "whoami", Timeout: 3})
	if err != nil || !strings.Contains(result, "agent authenticated") {
		t.Fatalf("agent auth: %q, %v", result, err)
	}
}
