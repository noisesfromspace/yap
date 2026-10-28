// Package lsp implements `yap lsp`: a language server for yap session
// transcripts. It provides document symbols, context-sensitive completion and
// structural diagnostics over the standard LSP protocol on stdio. The
// document structure comes from agent/document (the Go counterpart of the Lua
// structural parser); no feature here scans the transcript independently.
//
// The server is deliberately session-only: it serves a document only when its
// path is session.md beneath initializationOptions.sessions_dir. The Neovim
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

// contextParams is the yap/context notification: editor-owned state the
// server cannot infer from the session file (the live project cwd, and whether
// a reply is streaming into the tail).
type contextParams struct {
	URI       string `json:"uri"`
	Cwd       string `json:"cwd"`
	Streaming bool   `json:"streaming"`
}

// InitOptions are the initializationOptions the frontend passes.
type InitOptions struct {
	SessionsDir string `json:"sessions_dir"`
	AgentsDir   string `json:"agents_dir"`
}

// ─── Document store ────────────────────────────────────────────────────────

type docState struct {
	text      string
	version   int
	streaming bool
	cwd       string
	timer     *time.Timer
}

// Server owns open documents and the output channel.
type Server struct {
	opts   InitOptions
	docs   map[string]*docState
	outMu  sync.Mutex
	out    *bufio.Writer
	diagDelay time.Duration
}

// New returns a server writing responses/notifications to out.
func New(out io.Writer, opts InitOptions) *Server {
	return &Server{
		opts:   opts,
		docs:   map[string]*docState{},
		out:    bufio.NewWriter(out),
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
	case "textDocument/completion":
		var p completionParams
		if json.Unmarshal(req.Params, &p) == nil {
			s.respond(req.ID, s.completionFor(p))
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

// isSession reports whether uri points at session.md beneath sessions_dir.
func (s *Server) isSession(uri string) bool {
	p := uriToPath(uri)
	if p == "" || filepath.Base(p) != "session.md" {
		return false
	}
	if s.opts.SessionsDir == "" {
		return true // no sessions_dir configured: trust the client's attach scope
	}
	return strings.HasPrefix(p, s.opts.SessionsDir+string(filepath.Separator))
}

func (s *Server) didOpen(p didOpenParams) {
	d := &docState{text: p.TextDocument.Text, version: p.TextDocument.Version}
	s.docs[p.TextDocument.URI] = d
	if s.isSession(p.TextDocument.URI) {
		s.scheduleDiagnostics(p.TextDocument.URI, d)
	}
}

func (s *Server) didChange(p didChangeParams) {
	d := s.doc(p.TextDocument.URI)
	if d == nil {
		return
	}
	for _, ch := range p.ContentChanges {
		d.text = applyChange(d.text, ch)
	}
	d.version = p.TextDocument.Version
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
		return
	}
	wasStreaming := d.streaming
	d.cwd = p.Cwd
	d.streaming = p.Streaming
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
	diags := Diagnostics(d.text, d.streaming)
	s.notify("textDocument/publishDiagnostics", map[string]any{
		"uri":         uri,
		"version":     d.version,
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

func (s *Server) symbolsFor(uri string) any {
	if !s.isSession(uri) {
		return []any{}
	}
	d := s.doc(uri)
	if d == nil {
		return []any{}
	}
	return Symbols(d.text)
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
		Cwd:       d.cwd,
		AgentsDir: s.opts.AgentsDir,
	})
	return map[string]any{"isIncomplete": false, "items": items}
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
