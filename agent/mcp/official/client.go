// Package official adapts the Model Context Protocol Go SDK to Yap's MCP
// boundary. It is the only package that imports the SDK's mcp package.
package official

import (
	"context"
	"encoding/json"
	"fmt"
	"net/http"
	"os"
	"os/exec"
	"strings"
	"syscall"

	sdk "github.com/modelcontextprotocol/go-sdk/mcp"

	"boers.email/yap/agent/mcp"
)

// protocolVersion pins negotiation to a revision every tools-only server
// supports. The SDK defaults to 2026-07-28, which probes with server/discover
// before falling back to initialize; older stdio servers that silently ignore
// discover can stall that probe. Nothing Yap needs lives in the newer
// revisions, so pinning to 2025-11-25 skips the probe entirely.
const protocolVersion = "2025-11-25"

// Dial connects to one MCP server using the official Go SDK.
func Dial(ctx context.Context, cfg mcp.ServerConfig) (mcp.Client, error) {
	transport, err := selectTransport(cfg)
	if err != nil {
		return nil, err
	}
	var t sdk.Transport
	var cmd *exec.Cmd
	switch transport {
	case "stdio":
		cmd = exec.Command(cfg.Command, cfg.Args...)
		cmd.Dir = cfg.Cwd
		env, err := buildEnv(cfg.Env)
		if err != nil {
			return nil, err
		}
		cmd.Env = env
		cmd.SysProcAttr = &syscall.SysProcAttr{Setpgid: true}
		t = &sdk.CommandTransport{Command: cmd}
	case "http":
		headers := map[string]string{}
		for name, spec := range cfg.Headers {
			v, err := resolveHeader(spec)
			if err != nil {
				return nil, fmt.Errorf("header %q: %w", name, err)
			}
			headers[name] = v
		}
		t = &sdk.StreamableClientTransport{
			Endpoint:             cfg.URL,
			DisableStandaloneSSE: true, // tools are request/response; no server push needed
			HTTPClient:           headerClient(headers),
		}
	}

	cl := sdk.NewClient(&sdk.Implementation{Name: "yap", Version: "1"}, nil)
	sess, err := cl.Connect(ctx, t, &sdk.ClientSessionOptions{ProtocolVersion: protocolVersion})
	if err != nil {
		return nil, err
	}
	c := &client{session: sess}
	if transport == "stdio" {
		// Track the subprocess so Close can sweep any remaining group.
		c.cmd = cmd
	}
	return c, nil
}

// selectTransport resolves the transport name, inferring it when empty.
func selectTransport(cfg mcp.ServerConfig) (string, error) {
	t := strings.ToLower(strings.TrimSpace(cfg.Transport))
	if t == "" {
		switch {
		case cfg.Command != "":
			return "stdio", nil
		case cfg.URL != "":
			return "http", nil
		default:
			return "", fmt.Errorf("no command or url configured")
		}
	}
	switch t {
	case "stdio":
		return "stdio", nil
	case "http", "streamable-http", "streamable":
		return "http", nil
	default:
		return "", fmt.Errorf("unsupported transport %q", cfg.Transport)
	}
}

// buildEnv assembles the minimal child environment: PATH and HOME from Yap's
// own process, plus the configured variables resolved from their sources.
func buildEnv(extra map[string]string) ([]string, error) {
	env := []string{"PATH=" + os.Getenv("PATH")}
	if h := os.Getenv("HOME"); h != "" {
		env = append(env, "HOME="+h)
	}
	for dest, src := range extra {
		if dest == "" || strings.ContainsAny(dest, "\x00=") {
			return nil, fmt.Errorf("invalid env var name %q", dest)
		}
		v := os.Getenv(src)
		if v == "" {
			return nil, fmt.Errorf("env var %q (for %q) is not set", src, dest)
		}
		env = append(env, dest+"="+v)
	}
	return env, nil
}

// resolveHeader turns a header spec into its literal value. A spec is an
// environment-variable name, optionally prefixed by a literal scheme and a
// single space (e.g. "Bearer CENSYS_API_KEY"); the prefix is sent verbatim, so
// a server that needs "Authorization: Bearer <token>" can be expressed
// without embedding the token in settings.json.
func resolveHeader(spec string) (string, error) {
	src := spec
	var prefix string
	if i := strings.IndexByte(spec, ' '); i >= 0 {
		prefix, src = spec[:i+1], spec[i+1:]
	}
	v := os.Getenv(src)
	if v == "" {
		return "", fmt.Errorf("env var %q is not set", src)
	}
	return prefix + v, nil
}

// headerClient returns an HTTP client that sets headers on every request, or
// nil when no headers are configured.
func headerClient(headers map[string]string) *http.Client {
	if len(headers) == 0 {
		return nil
	}
	return &http.Client{Transport: headerRoundTripper{base: http.DefaultTransport, headers: headers}}
}

type headerRoundTripper struct {
	base    http.RoundTripper
	headers map[string]string
}

func (rt headerRoundTripper) RoundTrip(req *http.Request) (*http.Response, error) {
	r2 := req.Clone(req.Context())
	for k, v := range rt.headers {
		r2.Header.Set(k, v)
	}
	return rt.base.RoundTrip(r2)
}

type client struct {
	session *sdk.ClientSession
	cmd     *exec.Cmd // stdio subprocess; nil for http
}

func (c *client) ListTools(ctx context.Context) ([]mcp.Tool, error) {
	res, err := c.session.ListTools(ctx, nil)
	if err != nil {
		return nil, err
	}
	out := make([]mcp.Tool, 0, len(res.Tools))
	for _, t := range res.Tools {
		schema, err := json.Marshal(t.InputSchema)
		if err != nil {
			schema = nil
		}
		out = append(out, mcp.Tool{Name: t.Name, Description: t.Description, InputSchema: schema})
	}
	return out, nil
}

func (c *client) CallTool(ctx context.Context, name string, args json.RawMessage) (mcp.Result, error) {
	var a map[string]any
	if len(args) > 0 {
		if err := json.Unmarshal(args, &a); err != nil {
			return mcp.Result{}, fmt.Errorf("mcp %s: invalid arguments: %w", name, err)
		}
	}
	res, err := c.session.CallTool(ctx, &sdk.CallToolParams{Name: name, Arguments: a})
	if err != nil {
		return mcp.Result{}, err
	}
	return toResult(res), nil
}

func (c *client) Close() error {
	err := c.session.Close()
	// The stdio transport closes stdin and kills the direct child, but not
	// its process group; sweep any stragglers it left behind.
	if c.cmd != nil && c.cmd.Process != nil {
		_ = syscall.Kill(-c.cmd.Process.Pid, syscall.SIGKILL)
	}
	return err
}

func toResult(res *sdk.CallToolResult) mcp.Result {
	r := mcp.Result{IsError: res.IsError}
	for _, c := range res.Content {
		if b, err := json.Marshal(c); err == nil {
			r.Content = append(r.Content, b)
		}
	}
	if res.StructuredContent != nil {
		if b, err := json.Marshal(res.StructuredContent); err == nil {
			r.StructuredContent = b
		}
	}
	return r
}
