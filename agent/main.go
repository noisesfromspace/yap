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
//	yap serve                     # persistent backend per session buffer
//	yap models                    # list configured providers/models
//	yap tools                     # list compiled-in tool names
//	yap guard                     # list the compiled-in static guard rules (JSON)
//
// request.json: {"messages":[{"role":"system|user|assistant","content":"..."}]}
//
// Providers live in ~/.config/yap/settings.json; model pricing is the
// committed catalog in agent/price. Tools are Go files
// in the agent/tools/ package (one file per tool, self-registering) — edit and
// recompile to change them. Native providers (OpenAI Responses, Anthropic,
// Google/Gemini, DeepSeek) and any OpenAI-compatible /chat/completions
// endpoint (Moonshot/Kimi, OpenRouter, z.ai, ...) work via the GoAI adapter.
package main

import (
	"boers.email/yap/agent/tools"
	"boers.email/yap/agent/utils"
	"bufio"
	"encoding/json"
	"errors"
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
		fmt.Fprintln(os.Stderr, "usage: yap send --provider NAME --model MODEL < request.json\n       yap serve | models | tools | guard")
		os.Exit(2)
	}

	switch os.Args[1] {
	case "send":
		fs := flag.NewFlagSet("send", flag.ExitOnError)
		provider := fs.String("provider", "", "provider name from config.json")
		model := fs.String("model", "", "model name")
		_ = fs.Parse(os.Args[2:]) // ExitOnError: Parse exits on bad flags
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
	case "tools":
		// Print the compiled-in tool names (sorted, one per line) so the
		// frontend can render a session's `tools` allowlist in frontmatter.
		for _, t := range tools.All() {
			fmt.Println(t.Name)
		}
	case "guard":
		// Print the compiled-in static guard rules as one JSON array so the
		// frontend's guard board can render them without recompiling.
		out, err := json.Marshal(tools.Rules())
		if err != nil {
			fmt.Fprintln(os.Stderr, "yap:", err)
			os.Exit(1)
		}
		fmt.Println(string(out))
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}

// serve keeps tool state (including SSH connections) in this process across turns.
// All Go→Lua traffic is newline-delimited JSON frames on one channel (see
// agent/utils/frames.go): text, event, tool_output, request and turn_complete.
// One channel means total ordering, so the frontend needs no cross-pipe
// completion barrier.
type serveRequest struct {
	Request
	Provider string `json:"provider"`
	Model    string `json:"model"`
	V        int    `json:"v"`
}

// wireError maps a Go error onto the structured error object a turn_complete
// frame carries. A CodedError (request/params problem) keeps its code;
// everything else is an internal error.
func wireError(err error) *utils.WireError {
	if err == nil {
		return nil
	}
	var ce utils.CodedError
	if errors.As(err, &ce) {
		return &utils.WireError{Code: ce.Code, Message: ce.Error()}
	}
	return &utils.WireError{Code: utils.CodeInternal, Message: err.Error()}
}

func serve(in io.Reader, out io.Writer) error {
	tools.SubagentReplies = make(chan tools.SubagentReply, 1)
	utils.ApprovalReplies = make(chan utils.ApprovalReply, 1)
	defer func() {
		tools.SubagentReplies = nil
		utils.ApprovalReplies = nil
	}()
	// All Go→Lua traffic is framed JSON on stdout: text frames (buffer
	// content), event frames (audit), tool_output frames (live tail), and
	// request/turn_complete frames. One channel, total ordering.
	oldOut := utils.SetFrameWriter(out)
	defer utils.SetFrameWriter(oldOut)
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
					// Never block the stdin reader: this channel also carries
					// approvals and steering, and a reply can arrive for a call
					// that already timed out with nobody waiting.
					select {
					case tools.SubagentReplies <- reply.SubagentReply:
					default:
					}
					continue
				case "approval_result":
					var ar struct {
						ID       string `json:"id"`
						Approved bool   `json:"approved"`
					}
					_ = json.Unmarshal(line, &ar)
					select {
					case utils.ApprovalReplies <- utils.ApprovalReply{ID: ar.ID, Approved: ar.Approved}:
					default:
					}
					continue
				case "steer":
					updateMu.Lock()
					ch := updateCh
					updateMu.Unlock()
					if ch != nil {
						push(ch, update{steer: reply.Text}) // empty text cancels
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
		if err != nil {
			err = utils.CodedError{Code: utils.CodeParse, Err: err}
		} else if req.V != 1 {
			err = utils.CodedError{Code: utils.CodeInvalidReq, Err: fmt.Errorf("unsupported protocol version %d (want 1)", req.V)}
		} else if req.Provider == "" || req.Model == "" {
			err = utils.CodedError{Code: utils.CodeInvalidParam, Err: fmt.Errorf("provider and model are required")}
		} else {
			updateMu.Lock()
			updateCh = make(chan update, 1)
			ch := updateCh
			updateMu.Unlock()
			pendingSteer := ""
			hasSteer := false
			var pendProvider, pendModel string
			hasModel := false
			err = runTurn(req.Provider, req.Model, req.Request, utils.TextWriter(), func() boundary {
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
		// The terminal frame: every text/event/tool_output frame above is
		// already on the channel (one channel, total ordering), so the
		// frontend completes the turn on this frame alone.
		utils.EmitTurnComplete(err == nil, wireError(err))
	}
	return <-readErr
}
