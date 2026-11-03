// Package lsp implements `yap lsp`: a language server for yap session
// transcripts. It provides document symbols, context-sensitive completion and
// structural diagnostics over the standard LSP protocol on stdio. The
// document structure comes from agent/document (the Go counterpart of the Lua
// structural parser); no feature here scans the transcript independently.
//
// The server is deliberately session-only: it serves a document only when its
// path is a session transcript beneath initializationOptions.sessions_dir. The Neovim
// frontend additionally attaches the client only to managed (b:yap) buffers,
// so ordinary Markdown never reaches this server in practice.
package lsp

import (
	"bufio"
	"encoding/json"
	"fmt"
	"io"
	"net/url"
	"path/filepath"
	"strings"
	"sync"
	"time"

	"boers.email/yap/agent/document"
)

// ─── JSON-RPC / LSP wire types ─────────────────────────────────────────────

type position struct {
	Line      int `json:"line"`
	Character int `json:"character"`
}

type rng struct {
	Start position `json:"start"`
	End   position `json:"end"`
}

// request is the generic inbound JSON-RPC message. Params is kept raw so each
// handler decodes exactly the fields it needs.
type request struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type response struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id"`
	Result  any             `json:"result,omitempty"`
	Error   *respError      `json:"error,omitempty"`
}

type respError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
}

type notification struct {
	JSONRPC string `json:"jsonrpc"`
	Method  string `json:"method"`
	Params  any    `json:"params,omitempty"`
}

// didOpenParams / didChangeParams / didCloseParams carry document sync.
type didOpenParams struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
		Text    string `json:"text"`
	} `json:"textDocument"`
}

type changeEvent struct {
	Range rng    `json:"range"`
	Text  string `json:"text"`
}

type didChangeParams struct {
	TextDocument struct {
		URI     string `json:"uri"`
		Version int    `json:"version"`
	} `json:"textDocument"`
	ContentChanges []changeEvent `json:"contentChanges"`
}

type didCloseParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type textDocumentParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
}

type completionParams struct {
	TextDocument struct {
		URI string `json:"uri"`
	} `json:"textDocument"`
	Position position `json:"position"`
}

type codeActionParams struct {
	textDocumentParams
	Range rng `json:"range"`
}

// contextParams is the yap/context notification: editor-owned state the
// server cannot infer from the session file (the live project cwd, and whether
// a reply is streaming into the tail).
type contextParams struct {
	URI       string `json:"uri"`
	Cwd       string `json:"cwd"`
	Streaming bool   `json:"streaming"`
	// IsSession marks the document as a yap session from the client. The
	// client attaches the yap server only to session buffers, so a transcript
	// outside sessions_dir is still recognised (the server cannot infer that
	// from its path alone).
	IsSession bool `json:"is_session"`
}

// InitOptions are the initializationOptions the frontend passes.
type InitOptions struct {
	SessionsDir string `json:"sessions_dir"`
	AgentsDir   string `json:"agents_dir"`
	// ModelsCache is the path of the provider/model cache the frontend
	// writes from `yap models` (vim.fn.stdpath("cache") .. "/yap/models").
	// The server cannot derive it from os.UserCacheDir, which returns the
	// non-nvim-scoped XDG cache root.
	ModelsCache string `json:"models_cache"`
}

// ─── Document store ────────────────────────────────────────────────────────

type docState struct {
	// mu guards text/version/parsed, which a background warm parse reads
	// while the read loop keeps applying edits.
	mu            sync.Mutex
	text          string
	version       int
	streaming     bool
	cwd           string
	session       bool
	timer         *time.Timer
	parsed        *document.Document // cached parse of parsedVersion
	parsedVersion int
}

// parse returns the structural parse for the current text, reusing a warm
// result when one was computed for this version. Symbols and diagnostics both
// go through it, so a symbol request after a load reuses the warm parse (and
// vice versa).
func (d *docState) parse() *document.Document {
	d.mu.Lock()
	if d.parsed != nil && d.parsedVersion == d.version {
		p := d.parsed
		d.mu.Unlock()
		return p
	}
	text, version := d.text, d.version
	d.mu.Unlock()

	p := document.Parse(text)

	d.mu.Lock()
	if d.version == version {
		d.parsed, d.parsedVersion = p, version
	}
	d.mu.Unlock()
	return p
}

// warm parses in the background so the first symbol request after a session
// loads does not pay for it. The parse runs off the read loop and only lands
// when the document has not moved on in the meantime.
func (d *docState) warm() {
	d.mu.Lock()
	if d.parsed != nil && d.parsedVersion == d.version {
		d.mu.Unlock()
		return
	}
	text, version := d.text, d.version
	d.mu.Unlock()
	go func() {
		p := document.Parse(text)
		d.mu.Lock()
		if d.version == version {
			d.parsed, d.parsedVersion = p, version
		}
		d.mu.Unlock()
	}()
}

// Server owns open documents and the output channel.
type Server struct {
	opts      InitOptions
	docs      map[string]*docState
	pending   map[string]contextParams // context received before didOpen
	outMu     sync.Mutex
	out       *bufio.Writer
	diagDelay time.Duration
}

// New returns a server writing responses/notifications to out.
func New(out io.Writer, opts InitOptions) *Server {
	return &Server{
		opts:      opts,
		docs:      map[string]*docState{},
		pending:   map[string]contextParams{},
		out:       bufio.NewWriter(out),
		diagDelay: 200 * time.Millisecond,
	}
}

// Serve reads and dispatches LSP messages until the client sends `exit`.
func Serve(in io.Reader, out io.Writer) error {
	s := New(out, InitOptions{})
	r := bufio.NewReader(in)
	for {
		msg, err := readMessage(r)
		if err != nil {
			if err == io.EOF {
				return nil
			}
			return err
		}
		var req request
		if err := json.Unmarshal(msg, &req); err != nil {
			continue
		}
		if done := s.dispatch(req); done {
			return nil
		}
	}
}

// dispatch routes one message. It returns true when the client asked to exit.
func (s *Server) dispatch(req request) bool {
	// Notifications (no id) never get a response.
	if len(req.ID) == 0 || string(req.ID) == "null" {
		switch req.Method {
		case "exit":
			return true
		case "initialized":
		case "textDocument/didOpen":
			var p didOpenParams
			if json.Unmarshal(req.Params, &p) == nil {
				s.didOpen(p)
			}
		case "textDocument/didChange":
			var p didChangeParams
			if json.Unmarshal(req.Params, &p) == nil {
				s.didChange(p)
			}
		case "textDocument/didClose":
			var p didCloseParams
			if json.Unmarshal(req.Params, &p) == nil {
				s.didClose(p)
			}
		case "yap/context":
			var p contextParams
			if json.Unmarshal(req.Params, &p) == nil {
				s.setContext(p)
			}
		}
		return false
	}

	switch req.Method {
	case "initialize":
		var p struct {
			InitializationOptions InitOptions `json:"initializationOptions"`
		}
		_ = json.Unmarshal(req.Params, &p)
		s.opts = p.InitializationOptions
		s.respond(req.ID, s.initializeResult())
	case "shutdown":
		s.respond(req.ID, nil)
	case "textDocument/documentSymbol":
		var p textDocumentParams
		if json.Unmarshal(req.Params, &p) == nil {
			s.respond(req.ID, s.symbolsFor(p.TextDocument.URI))
		}
	case "textDocument/codeAction":
		var p codeActionParams
		if json.Unmarshal(req.Params, &p) == nil {
			s.respond(req.ID, s.codeActionsFor(p))
		}
	case "textDocument/completion":
		var p completionParams
		if json.Unmarshal(req.Params, &p) == nil {
			s.respond(req.ID, s.completionFor(p))
		}
	case "yap/messages":
		// The transcript → request conversion is Go-owned
		// (R-single-reader), so the frontend queries it rather than
		// re-deriving the flatten/merge rules in Lua. Not part of LSP:
		// a Yap extension on the same channel and document store.
		var p struct {
			textDocumentParams
			Text string `json:"text"`
		}
		if json.Unmarshal(req.Params, &p) == nil {
			if p.Text != "" {
				s.respond(req.ID, document.Messages(p.Text))
			} else {
				s.respond(req.ID, s.messagesFor(p.TextDocument.URI))
			}
		}
	default:
		s.respondError(req.ID, -32601, "method not found: "+req.Method)
	}
	return false
}

// ─── Framing ───────────────────────────────────────────────────────────────

func readMessage(r *bufio.Reader) ([]byte, error) {
	length := -1
	for {
		line, err := r.ReadString('\n')
		if err != nil {
			return nil, err
		}
		line = strings.TrimRight(line, "\r\n")
		if line == "" {
			break
		}
		if rest, ok := strings.CutPrefix(line, "Content-Length:"); ok {
			_, _ = fmt.Sscanf(strings.TrimSpace(rest), "%d", &length)
		}
	}
	if length < 0 {
		return nil, fmt.Errorf("lsp: missing Content-Length header")
	}
	buf := make([]byte, length)
	if _, err := io.ReadFull(r, buf); err != nil {
		return nil, err
	}
	return buf, nil
}

func (s *Server) write(v any) {
	b, err := json.Marshal(v)
	if err != nil {
		return
	}
	s.outMu.Lock()
	defer s.outMu.Unlock()
	_, _ = fmt.Fprintf(s.out, "Content-Length: %d\r\n\r\n", len(b))
	_, _ = s.out.Write(b)
	_ = s.out.Flush()
}

func (s *Server) respond(id json.RawMessage, result any) {
	if result == nil {
		// A response must carry result or error. `shutdown` has a null result;
		// omitting it makes Neovim report INVALID_SERVER_MESSAGE on every
		// clean exit.
		result = json.RawMessage("null")
	}
	s.write(response{JSONRPC: "2.0", ID: id, Result: result})
}

func (s *Server) respondError(id json.RawMessage, code int, msg string) {
	s.write(response{JSONRPC: "2.0", ID: id, Error: &respError{Code: code, Message: msg}})
}

func (s *Server) notify(method string, params any) {
	s.write(notification{JSONRPC: "2.0", Method: method, Params: params})
}

// ─── Document lifecycle ────────────────────────────────────────────────────

func (s *Server) doc(uri string) *docState {
	if d, ok := s.docs[uri]; ok {
		return d
	}
	return nil
}

// isSession reports whether uri points at a session transcript: any markdown
// file except the scratch notes.md sidecar (the transcript is renamed to set
// the session title), that is either under sessions_dir or marked as a session
// by the client via yap/context.
func (s *Server) isSession(uri string) bool {
	p := uriToPath(uri)
	base := filepath.Base(p)
	if p == "" || !strings.HasSuffix(base, ".md") || base == "notes.md" {
		return false
	}
	if d := s.docs[uri]; d != nil && d.session {
		return true
	}
	if s.opts.SessionsDir == "" {
		return true // no sessions_dir configured: trust the client's attach scope
	}
	return strings.HasPrefix(p, s.opts.SessionsDir+string(filepath.Separator))
}

func (s *Server) didOpen(p didOpenParams) {
	d := &docState{text: p.TextDocument.Text, version: p.TextDocument.Version}
	// The frontend may have sent yap/context before didOpen was processed
	// (buf_attach_client sends didOpen asynchronously). Apply any pending
	// context now instead of dropping the cwd, which file completion needs.
	if c, ok := s.pending[p.TextDocument.URI]; ok {
		d.cwd = c.Cwd
		d.streaming = c.Streaming
		d.session = c.IsSession
		delete(s.pending, p.TextDocument.URI)
	}
	s.docs[p.TextDocument.URI] = d
	if s.isSession(p.TextDocument.URI) {
		// Parse ahead of the first symbol request; the read loop stays free.
		d.warm()
		s.scheduleDiagnostics(p.TextDocument.URI, d)
	}
}

func (s *Server) didChange(p didChangeParams) {
	d := s.doc(p.TextDocument.URI)
	if d == nil {
		return
	}
	for _, ch := range p.ContentChanges {
		d.mu.Lock()
		d.text = applyChange(d.text, ch)
		d.mu.Unlock()
	}
	d.mu.Lock()
	d.version = p.TextDocument.Version
	d.mu.Unlock()
	if s.isSession(p.TextDocument.URI) {
		s.scheduleDiagnostics(p.TextDocument.URI, d)
	}
}

func (s *Server) didClose(p didCloseParams) {
	d := s.docs[p.TextDocument.URI]
	if d != nil && d.timer != nil {
		d.timer.Stop()
	}
	delete(s.docs, p.TextDocument.URI)
}

func (s *Server) setContext(p contextParams) {
	d := s.doc(p.URI)
	if d == nil {
		// didOpen has not arrived yet (buf_attach_client schedules it);
		// keep the context for didOpen to apply.
		s.pending[p.URI] = p
		return
	}
	wasStreaming := d.streaming
	d.cwd = p.Cwd
	d.streaming = p.Streaming
	d.session = p.IsSession
	// The context notification can race didOpen, so a document marked as a
	// session here may have missed didOpen's warm/diagnostics pass.
	if d.session {
		d.warm()
		s.scheduleDiagnostics(p.URI, d)
	}
	// A stream that just finished leaves the final document to validate.
	if wasStreaming && !p.Streaming {
		s.scheduleDiagnostics(p.URI, d)
	}
}

// scheduleDiagnostics debounces validation so per-keystroke edits do not
// re-parse and re-publish on every change.
func (s *Server) scheduleDiagnostics(uri string, d *docState) {
	if d.timer != nil {
		d.timer.Stop()
	}
	d.timer = time.AfterFunc(s.diagDelay, func() {
		s.publishDiagnostics(uri, d)
	})
}

func (s *Server) publishDiagnostics(uri string, d *docState) {
	if _, ok := s.docs[uri]; !ok {
		return
	}
	diags := diagnosticsFromDoc(d.parse(), d.streaming)
	d.mu.Lock()
	version := d.version
	d.mu.Unlock()
	s.notify("textDocument/publishDiagnostics", map[string]any{
		"uri":         uri,
		"version":     version,
		"diagnostics": diags,
	})
}

// ─── Feature dispatch ──────────────────────────────────────────────────────

func (s *Server) initializeResult() map[string]any {
	return map[string]any{
		"capabilities": map[string]any{
			"positionEncoding": "utf-16",
			"textDocumentSync": map[string]any{
				"openClose": true,
				"change":    2, // incremental
			},
			"documentSymbolProvider": true,
			"codeActionProvider":     true,
			"completionProvider": map[string]any{
				"triggerCharacters": []string{"@", "#", ":", "-"},
			},
		},
		"serverInfo": map[string]any{
			"name":    "yap",
			"version": "0",
		},
	}
}

// messagesFor returns the messages a send would derive from the document.
// Always an array: a nil slice marshals to `null`, which Lua's vim.json.decode
// turns into vim.NIL and callers cannot iterate.
func (s *Server) messagesFor(uri string) any {
	if !s.isSession(uri) {
		return []document.Message{}
	}
	d := s.doc(uri)
	if d == nil {
		return []document.Message{}
	}
	return document.Messages(d.text)
}

func (s *Server) symbolsFor(uri string) any {
	if !s.isSession(uri) {
		return []any{}
	}
	d := s.doc(uri)
	if d == nil {
		return []any{}
	}
	return symbolsFromDoc(d.parse())
}

func (s *Server) completionFor(p completionParams) any {
	if !s.isSession(p.TextDocument.URI) {
		return map[string]any{"isIncomplete": false, "items": []any{}}
	}
	d := s.doc(p.TextDocument.URI)
	if d == nil {
		return map[string]any{"isIncomplete": false, "items": []any{}}
	}
	items := Completion(d.text, p.Position.Line, p.Position.Character, CompletionCtx{
		Cwd:         d.cwd,
		AgentsDir:   s.opts.AgentsDir,
		ModelsCache: s.opts.ModelsCache,
	})
	if items == nil {
		// A nil slice marshals to `null`, which Neovim rejects for a
		// CompletionList.items (expected a CompletionItem[]).
		items = []completionItem{}
	}
	return map[string]any{"isIncomplete": false, "items": items}
}

// codeActionsFor offers only repairs whose insertion point is determined by
// the structural parse. In particular, a tool with an unfinished header is
// not safe to close with a tool-region marker.
func (s *Server) codeActionsFor(p codeActionParams) any {
	out := []any{}
	uri := p.TextDocument.URI
	if !s.isSession(uri) {
		return out
	}
	d := s.doc(uri)
	if d == nil || d.streaming {
		return out
	}
	doc := d.parse()
	if len(doc.Lines) > 0 && doc.Lines[0] == "---" && doc.Frontmatter == 0 && p.Range.Start.Line == 0 {
		line := len(doc.Lines) - 1
		if len(doc.Headings) > 0 {
			line = doc.Headings[0].Line - 1
		}
		insert := position{Line: line}
		text := "---\n"
		if line == len(doc.Lines)-1 && len(doc.Headings) == 0 {
			insert.Character = len(doc.Lines[line])
			text = "\n---"
		}
		out = append(out, map[string]any{
			"title": "Close frontmatter", "kind": "quickfix",
			"edit": map[string]any{"changes": map[string]any{uri: []textEdit{{Range: rng{Start: insert, End: insert}, NewText: text}}}},
		})
	}
	for _, r := range doc.Regions {
		if r.Kind != "tool" || (r.Finish != 0 && !r.Unclosed) || r.HeaderFinish == 0 {
			continue
		}
		where := regionRange(doc.Lines, r)
		if p.Range.End.Line < where.Start.Line || p.Range.Start.Line > where.End.Line {
			continue
		}
		line := len(doc.Lines) - 1
		if r.Unclosed {
			line = r.Finish - 1
		}
		// Insert after the last tool line, before a recovered heading if
		// present. At EOF, reuse the trailing empty line when available.
		insert := position{Line: line + 1}
		text := "<!-- /yap:tool -->\n"
		if line == len(doc.Lines)-1 {
			insert = position{Line: line, Character: len(doc.Lines[line])}
			text = "\n<!-- /yap:tool -->"
		}
		out = append(out, map[string]any{
			"title": "Close tool region", "kind": "quickfix",
			"edit": map[string]any{"changes": map[string]any{uri: []textEdit{{Range: rng{Start: insert, End: insert}, NewText: text}}}},
		})
	}
	return out
}

// uriToPath converts a file:// URI to a filesystem path.
func uriToPath(uri string) string {
	u, err := url.Parse(uri)
	if err != nil || u.Scheme != "file" {
		return ""
	}
	p := u.Path
	if p == "" {
		return ""
	}
	if unesc, err := url.PathUnescape(p); err == nil {
		p = unesc
	}
	return filepath.Clean(p)
}
