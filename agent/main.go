// yap — LLM backend for the yap Neovim plugin.
//
// The Neovim buffer is the conversation; this binary is the provider
// client and agent loop. It reads a JSON request on stdin and streams the
// assistant reply to stdout as plain text, interleaved with yap:tool
// blocks when the model calls tools. Errors go to stderr with exit 1.
//
// Usage:
//
//	yap send --provider NAME --model MODEL < request.json
//
// request.json: {"messages":[{"role":"system|user|assistant","content":"..."}]}
//
// Providers and pricing live in ~/.config/yap.json. Tools are Go files
// in the agent/tools/ package (one file per tool, self-registering) — edit and
// recompile to change them. Native providers (OpenAI Responses, Anthropic,
// Google/Gemini, DeepSeek) and any OpenAI-compatible /chat/completions
// endpoint (Moonshot/Kimi, OpenRouter, z.ai, ...) work via the GoAI adapter.
package main

import (
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/utils"
	"bufio"
	"bytes"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
	"os/signal"
	"sync"
	"syscall"
)

func main() {
	defer tools.CloseAll()
	// :YapStop terminates the persistent backend. Kill tracked local
	// tool process groups as well; one handler serves every turn.
	sig := make(chan os.Signal, 1)
	signal.Notify(sig, os.Interrupt, syscall.SIGTERM)
	go func() {
		<-sig
		utils.KillAll()
		tools.CloseAll()
		fmt.Fprintln(os.Stderr, "interrupted")
		os.Exit(1)
	}()
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: yap send --provider NAME --model MODEL < request.json")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "send":
		fs := flag.NewFlagSet("send", flag.ExitOnError)
		provider := fs.String("provider", "", "provider name from config.json")
		model := fs.String("model", "", "model name")
		fs.Parse(os.Args[2:])
		if *provider == "" || *model == "" {
			fmt.Fprintln(os.Stderr, "send: --provider and --model are required")
			os.Exit(2)
		}
		if err := send(*provider, *model, os.Stdin, os.Stdout); err != nil {
			tools.CloseAll()
			fmt.Fprintln(os.Stderr, "yap:", err)
			os.Exit(1)
		}
	case "serve":
		if err := serve(os.Stdin, os.Stdout); err != nil {
			tools.CloseAll()
			fmt.Fprintln(os.Stderr, "yap:", err)
			os.Exit(1)
		}
	case "models":
		if err := models(); err != nil {
			fmt.Fprintln(os.Stderr, "yap:", err)
			os.Exit(1)
		}
	case "fetch-worker":
		// Internal subcommand: performs a single SSRF-checked GET and writes
		// the framed result to stdout. Invoked by the fetch tool's vpn path,
		// which re-execs this binary under the `vpn.command` prefix.
		if len(os.Args) < 3 {
			fmt.Fprintln(os.Stderr, "fetch-worker: missing URL")
			os.Exit(2)
		}
		if err := tools.RunFetchWorker(os.Args[2], os.Stdout); err != nil {
			fmt.Fprintln(os.Stderr, "yap:", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

// serve keeps tool state (including SSH connections) in this process across turns.
// RS cannot appear in streamed content: turnOutput strips it before writing.
const turnEnd = "\x1eyap:turn_end "

type serveRequest struct {
	Request
	Provider string `json:"provider"`
	Model    string `json:"model"`
}

type turnOutput struct{ w io.Writer }

func (o turnOutput) Write(p []byte) (int, error) {
	_, err := o.w.Write(bytes.ReplaceAll(p, []byte{0x1e}, []byte("?")))
	return len(p), err
}

func serve(in io.Reader, out io.Writer) error {
	tools.SubagentReplies = make(chan tools.SubagentReply, 1)
	utils.ApprovalReplies = make(chan utils.ApprovalReply, 1)
	defer func() {
		tools.SubagentReplies = nil
		utils.ApprovalReplies = nil
	}()
	requests := make(chan []byte)
	readErr := make(chan error, 1)

	// Mid-turn injections: a channel the currently-running turn polls for
	// steering messages and model switches. Scoped to one turn at a time —
	// an injection arriving while no turn is running is dropped, because the
	// frontend only sends one while its buffer is streaming and degrades a
	// missed steer into a follow-up turn itself.
	type update struct {
		steer    string
		provider string
		model    string
	}
	var updateMu sync.Mutex
	var updateCh chan update

	// push delivers an update to the running turn, always keeping the latest
	// one (an older pending steer/model is superseded, not queued).
	push := func(ch chan update, u update) {
		select {
		case ch <- u:
		default:
			select {
			case <-ch:
			default:
			}
			ch <- u
		}
	}

	go func() {
		scanner := bufio.NewScanner(in)
		scanner.Buffer(make([]byte, 4096), 16*1024*1024)
		for scanner.Scan() {
			line := append([]byte(nil), scanner.Bytes()...)
			var reply struct {
				Type     string `json:"type"`
				Text     string `json:"text"`
				Provider string `json:"provider"`
				Model    string `json:"model"`
				tools.SubagentReply
			}
			if json.Unmarshal(line, &reply) == nil {
				switch reply.Type {
				case "subagent_result":
					tools.SubagentReplies <- reply.SubagentReply
					continue
				case "approval_result":
					var ar struct {
						ID       string `json:"id"`
						Approved bool   `json:"approved"`
					}
					json.Unmarshal(line, &ar)
					utils.ApprovalReplies <- utils.ApprovalReply{ID: ar.ID, Approved: ar.Approved}
					continue
				case "steer", "unsteer":
					updateMu.Lock()
					ch := updateCh
					updateMu.Unlock()
					if ch != nil {
						text := reply.Text
						if reply.Type == "unsteer" {
							text = ""
						}
						push(ch, update{steer: text})
					}
					continue
				case "model":
					updateMu.Lock()
					ch := updateCh
					updateMu.Unlock()
					if ch != nil {
						push(ch, update{provider: reply.Provider, model: reply.Model})
					}
					continue
				}
			}
			requests <- line
		}
		readErr <- scanner.Err()
		close(requests)
	}()

	for line := range requests {
		var req serveRequest
		err := json.Unmarshal(line, &req)
		if err == nil {
			if req.Provider == "" || req.Model == "" {
				err = fmt.Errorf("provider and model are required")
			} else {
				updateMu.Lock()
				updateCh = make(chan update, 1)
				ch := updateCh
				updateMu.Unlock()
				pendingSteer := ""
				hasSteer := false
				var pendProvider, pendModel string
				hasModel := false
				err = runTurn(req.Provider, req.Model, req.Request, turnOutput{out}, func() boundary {
					for {
						select {
						case u := <-ch:
							if u.provider != "" {
								pendProvider, pendModel, hasModel = u.provider, u.model, true
							} else {
								pendingSteer = u.steer
								hasSteer = pendingSteer != ""
							}
						default:
							b := boundary{}
							if hasModel {
								b.provider, b.model = pendProvider, pendModel
								hasModel = false
								pendProvider, pendModel = "", ""
							}
							if hasSteer {
								b.steer = pendingSteer
								hasSteer = false
								pendingSteer = ""
							}
							return b
						}
					}
				})
				updateMu.Lock()
				if updateCh == ch {
					updateCh = nil
				}
				updateMu.Unlock()
			}
		}
		if err != nil {
			fmt.Fprintln(os.Stderr, "yap:", err)
		}
		// The RS prefix marks the sentinel even after prose without a newline.
		status := map[string]any{"ok": err == nil}
		if err != nil {
			status["error"] = err.Error()
		}
		end, _ := json.Marshal(status)
		if _, writeErr := fmt.Fprintf(out, "%s%s\n", turnEnd, end); writeErr != nil {
			return writeErr
		}
		// stderr events and stdout have independent pipes; the frontend
		// completes only after receiving both this barrier and the sentinel.
		utils.EmitEvent(map[string]string{"type": "turn_complete"})
	}
	return <-readErr
}
