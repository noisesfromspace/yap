// pitel — LLM backend for the pitel Neovim plugin.
//
// The Neovim buffer is the conversation; this binary is the provider
// client and agent loop. It reads a JSON request on stdin and streams the
// assistant reply to stdout as plain text, interleaved with pitel:tool
// blocks when the model calls tools. Errors go to stderr with exit 1.
//
// Usage:
//
//	pitel send --provider NAME --model MODEL < request.json
//
// request.json: {"messages":[{"role":"system|user|assistant|tool", ...}]}
//
// Providers and pricing live in ~/.pitel/config.json. Tools are Go files
// in the tools/ package (one file per tool, self-registering) — edit and
// recompile to change them. Any OpenAI-compatible /chat/completions
// endpoint works (OpenAI, DeepSeek, Moonshot/Kimi, OpenRouter, z.ai, ...).
package main

import (
	"flag"
	"fmt"
	"os"
)

func main() {
	if len(os.Args) < 2 {
		fmt.Fprintln(os.Stderr, "usage: pitel send --provider NAME --model MODEL < request.json")
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
		if err := send(*provider, *model); err != nil {
			fmt.Fprintln(os.Stderr, "pitel:", err)
			os.Exit(1)
		}
	default:
		fmt.Fprintf(os.Stderr, "unknown command %q\n", os.Args[1])
		os.Exit(2)
	}
}
