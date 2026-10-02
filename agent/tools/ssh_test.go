package tools

import (
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
	known := filepath.Join(dir, "known_hosts")
	os.WriteFile(known, []byte(""), 0600)
	if _, err := runSSH(args); err == nil || !strings.Contains(err.Error(), "knownhosts") && !strings.Contains(err.Error(), "known host") {
		t.Fatalf("untrusted host accepted: %v", err)
	}
	line := fmt.Sprintf("[%s]:%d %s %s\n", host, port, signer.PublicKey().Type(), base64.StdEncoding.EncodeToString(signer.PublicKey().Marshal()))
	if err := os.WriteFile(known, []byte(line), 0600); err != nil {
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
