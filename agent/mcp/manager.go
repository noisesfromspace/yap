package mcp

import (
	"context"
	"encoding/json"
	"fmt"
	"hash/fnv"
	"sort"
	"strings"
	"sync"
	"time"
	"unicode/utf8"
)

const (
	// maxToolNameRunes is the provider limit on a public tool name.
	maxToolNameRunes = 64
	// maxServerRunes caps the server part of a public name so a long server
	// name cannot crowd out the tool name it prefixes.
	maxServerRunes = 24
	// nameHashLen is the length of the suffix that keeps two truncated names
	// distinct: an underscore plus 8 hex digits.
	nameHashLen = 9

	// maxLoaderDescription caps the summary a lazy server puts in context on
	// every turn. Without it a server with hundreds of tools could cost more
	// there than the eager definitions lazy mode replaces.
	maxLoaderDescription = 4000
)

// syncTimeout bounds connect + tools/list for one server. Sync runs with the
// manager lock held, so a server that never answers would otherwise stall the
// turn (and every tool call behind the lock). A timed-out server is retried
// next turn, since nothing is cached for it. A var so tests can shorten it.
var syncTimeout = 60 * time.Second

// Manager keeps one connected client per configured server for the lifetime
// of the backend. Tools are discovered once per connection and cached; a
// reconnect (config change) re-lists them. The call path releases the lock
// before talking to a server, so a slow tool never blocks Sync.
type Manager struct {
	dial    Dial
	mu      sync.Mutex
	servers map[string]*server
}

type server struct {
	name   string
	cfg    ServerConfig
	client Client
	pub    map[string]toolInfo // public name -> discovered tool
	order  []string            // sorted public names
	// warnings holds load-time problems (a dropped tool, ...) for the next
	// Sync to report. An error that costs one tool must not cost the server.
	warnings []string
}

type toolInfo struct {
	original string
	desc     string
	schema   json.RawMessage
}

// NewManager returns a Manager using dial to connect to servers.
func NewManager(dial Dial) *Manager {
	if dial == nil {
		dial = func(context.Context, ServerConfig) (Client, error) {
			return nil, fmt.Errorf("no MCP dial configured")
		}
	}
	return &Manager{dial: dial, servers: map[string]*server{}}
}

// Sync reconciles the manager with cfg and returns the currently available
// tools plus one error per unavailable server (or per tool a server had to
// drop). Tools are still returned when some servers fail, so an optional
// server never blocks the turn. Servers whose config is unchanged keep their
// cached tool list; only a newly connected (or reconnected) server lists
// tools.
func (m *Manager) Sync(ctx context.Context, cfg map[string]ServerConfig) ([]Tool, []error) {
	m.mu.Lock()
	defer m.mu.Unlock()

	// Close servers no longer configured.
	for name, s := range m.servers {
		if _, ok := cfg[name]; !ok {
			_ = s.client.Close()
			delete(m.servers, name)
		}
	}

	var tools []Tool
	var errs []error
	names := make([]string, 0, len(cfg))
	for name := range cfg {
		names = append(names, name)
	}
	sort.Strings(names)

	seen := map[string]string{} // public name -> "server/tool", for collisions
	for _, name := range names {
		sc := cfg[name]
		s, err := m.ensureLocked(ctx, name, sc)
		if err != nil {
			errs = append(errs, fmt.Errorf("mcp server %q: %w", name, err))
			continue
		}
		for _, w := range s.warnings {
			errs = append(errs, fmt.Errorf("mcp server %q: %s", name, w))
		}
		s.warnings = nil
		if sc.Lazy {
			// A lazy server exposes one loader tool until the model asks for
			// its real tools (see Activate); its definitions stay out of
			// context otherwise.
			if len(s.order) == 0 {
				continue // nothing to load
			}
			lt := loaderTool(name, s)
			if prev, ok := seen[lt.Name]; ok {
				errs = append(errs, fmt.Errorf("mcp loader %q collides with %s", lt.Name, prev))
				continue
			}
			seen[lt.Name] = name + "/loader"
			tools = append(tools, lt)
			continue
		}
		for _, pub := range s.order {
			if prev, ok := seen[pub]; ok {
				errs = append(errs, fmt.Errorf("mcp tool %q collides with %s", pub, prev))
				continue
			}
			seen[pub] = name + "/" + s.pub[pub].original
			info := s.pub[pub]
			tools = append(tools, Tool{Name: pub, Description: info.desc, InputSchema: info.schema, Server: name})
		}
	}
	return tools, errs
}

// ensureLocked returns the client for name, reusing it when the config is
// unchanged and reconnecting when it changed.
func (m *Manager) ensureLocked(ctx context.Context, name string, cfg ServerConfig) (*server, error) {
	if s, ok := m.servers[name]; ok && configEqual(s.cfg, cfg) {
		return s, nil
	}
	if s, ok := m.servers[name]; ok {
		_ = s.client.Close()
		delete(m.servers, name)
	}
	ctx, cancel := context.WithTimeout(ctx, syncTimeout)
	defer cancel()
	cl, err := m.dial(ctx, cfg)
	if err != nil {
		return nil, err
	}
	s := &server{name: name, cfg: cfg, client: cl, pub: map[string]toolInfo{}}
	if err := s.load(ctx); err != nil {
		_ = cl.Close()
		return nil, err
	}
	m.servers[name] = s
	return s, nil
}

// load lists the server's tools once and builds the public-name mapping,
// honoring the configured allowlist. It runs only on connect/reconnect: the
// list is cached for the connection's lifetime. tools/list_changed
// notifications would let us refresh in place, but they are only negotiated
// at protocol 2026-07-28+ (which Yap pins away from to skip the SDK's
// server/discover probe), so a server's tools are re-read on reconnect only.
func (s *server) load(ctx context.Context) error {
	list, err := s.client.ListTools(ctx)
	if err != nil {
		return err
	}
	allow := map[string]bool{}
	if s.cfg.Tools != nil {
		for _, t := range s.cfg.Tools {
			allow[t] = true
		}
	}
	pub := map[string]toolInfo{}
	var order, warnings []string
	for _, t := range list {
		if s.cfg.Tools != nil && !allow[t.Name] {
			continue
		}
		p := publicName(s.name, t.Name)
		if prev, ok := pub[p]; ok {
			// Keep the first tool and drop the rest: one collision must not
			// take the whole server down with it (it once did).
			warnings = append(warnings, fmt.Sprintf("tools %q and %q both map to %q; exposing %q", prev.original, t.Name, p, prev.original))
			continue
		}
		pub[p] = toolInfo{original: t.Name, desc: t.Description, schema: t.InputSchema}
		order = append(order, p)
	}
	sort.Strings(order)
	s.pub = pub
	s.order = order
	s.warnings = warnings
	return nil
}

// Activate returns a lazy server's tools, ready to be registered mid-turn so
// the model can call them in its next request. It errors for an unknown
// server or one that is not lazy.
func (m *Manager) Activate(name string) ([]Tool, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	s, ok := m.servers[name]
	if !ok {
		return nil, fmt.Errorf("unknown MCP server %q", name)
	}
	if !s.cfg.Lazy {
		return nil, fmt.Errorf("MCP server %q is not lazy", name)
	}
	out := make([]Tool, 0, len(s.order))
	for _, pub := range s.order {
		info := s.pub[pub]
		out = append(out, Tool{Name: pub, Description: info.desc, InputSchema: info.schema, Server: name})
	}
	return out, nil
}

// LoaderFor reports whether publicName is a tool of a lazy server and, if so,
// the loader tool that activates it. The agent loop uses it to turn a call to
// an unregistered lazy tool (activation lasts one turn) into actionable
// advice instead of a bare "unknown tool".
func (m *Manager) LoaderFor(publicName string) (string, bool) {
	m.mu.Lock()
	defer m.mu.Unlock()
	for name, s := range m.servers {
		if !s.cfg.Lazy {
			continue
		}
		if _, ok := s.pub[publicName]; ok {
			return loaderName(name), true
		}
	}
	return "", false
}

// Call invokes the tool behind publicName with args, returning the normalized
// result text.
func (m *Manager) Call(ctx context.Context, publicName string, args json.RawMessage) (string, error) {
	m.mu.Lock()
	var cl Client
	var original string
	for _, s := range m.servers {
		if info, ok := s.pub[publicName]; ok {
			cl, original = s.client, info.original
			break
		}
	}
	m.mu.Unlock()
	if cl == nil {
		return "", fmt.Errorf("unknown MCP tool %q", publicName)
	}
	res, err := cl.CallTool(ctx, original, args)
	if err != nil {
		return "", err
	}
	return res.Text(), nil
}

// Close disconnects every server.
func (m *Manager) Close() {
	m.mu.Lock()
	defer m.mu.Unlock()
	for name, s := range m.servers {
		_ = s.client.Close()
		delete(m.servers, name)
	}
}

// loaderName is the public name of a lazy server's loader tool.
func loaderName(serverName string) string {
	return "mcp_" + sanitize(serverName, maxServerRunes)
}

// publicName namespaces a server's tool as mcp_<server>_<tool>, spending the
// provider's name budget on the tool name rather than a fixed slice of it.
func publicName(serverName, tool string) string {
	prefix := loaderName(serverName) + "_"
	return prefix + sanitize(tool, maxToolNameRunes-len(prefix))
}

// loaderTool builds the single tool a lazy server exposes before activation.
// Its description summarizes what the server offers (names + clipped one-line
// descriptions) so the model can decide whether to pull the real definitions
// in; the full schemas are only fetched when it does.
// The names it lists are the public ones, because those are what the model
// can actually call; a truncated public name would be unusable to it.
func loaderTool(name string, s *server) Tool {
	var b strings.Builder
	b.WriteString("Load the tools of the ")
	b.WriteString(name)
	b.WriteString(" MCP server. Call this tool first, then call the listed tools directly:")
	listed := 0
	for _, pub := range s.order {
		entry := " " + pub + " — " + clip(s.pub[pub].desc, 60) + ";"
		if b.Len()+len(entry) > maxLoaderDescription {
			break
		}
		b.WriteString(entry)
		listed++
	}
	if rest := len(s.order) - listed; rest > 0 {
		fmt.Fprintf(&b, " and %d more not listed here.", rest)
	}
	return Tool{
		Name:        loaderName(name),
		Description: b.String(),
		InputSchema: json.RawMessage(`{"type":"object"}`),
		Server:      name,
		Loader:      true,
	}
}

// clip collapses whitespace and truncates s to at most n runes, never
// splitting a multi-byte character: half a rune makes a provider reject the
// request, and makes Neovim read the transcript back as latin1.
func clip(s string, n int) string {
	s = strings.Join(strings.Fields(s), " ")
	if utf8.RuneCountInString(s) <= n {
		return s
	}
	return string([]rune(s)[:n]) + "…"
}

// sanitize maps a name onto the conservative set model providers accept
// (letters, digits, underscore, hyphen) and truncates it to at most max
// runes. Truncation keeps a short hash of the full name so two distinct long
// names that share a prefix (e.g. list_available_data_definition_groups vs
// ..._definitions) do not collapse onto the same public name. Non-ASCII runs
// become '_', so the result is pure ASCII and runes equal bytes.
func sanitize(s string, max int) string {
	var b strings.Builder
	for _, r := range s {
		switch {
		case r >= 'a' && r <= 'z', r >= 'A' && r <= 'Z', r >= '0' && r <= '9', r == '_', r == '-':
			b.WriteRune(r)
		default:
			b.WriteByte('_')
		}
	}
	out := b.String()
	if out == "" {
		out = "tool"
	}
	if len(out) <= max {
		return out
	}
	if max <= nameHashLen {
		return out[:max]
	}
	h := fnv.New32a()
	_, _ = h.Write([]byte(out))
	return out[:max-nameHashLen] + "_" + fmt.Sprintf("%08x", h.Sum32())
}

func configEqual(a, b ServerConfig) bool {
	return a.Lazy == b.Lazy &&
		a.Transport == b.Transport &&
		a.Command == b.Command &&
		strings.Join(a.Args, "\x00") == strings.Join(b.Args, "\x00") &&
		a.Cwd == b.Cwd &&
		a.URL == b.URL &&
		equalStringMap(a.Env, b.Env) &&
		equalStringMap(a.Headers, b.Headers) &&
		equalStringSlice(a.Tools, b.Tools)
}

func equalStringMap(a, b map[string]string) bool {
	if len(a) != len(b) {
		return false
	}
	for k, v := range a {
		if b[k] != v {
			return false
		}
	}
	return true
}

func equalStringSlice(a, b []string) bool {
	// nil (expose all) and empty (expose none) are distinct for a Tools
	// allowlist, so they must not compare equal.
	if (a == nil) != (b == nil) {
		return false
	}
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}
