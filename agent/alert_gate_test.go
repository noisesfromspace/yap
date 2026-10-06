package main

import (
	"encoding/json"
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestGateStatePythonFile(t *testing.T) {
	p := filepath.Join(t.TempDir(), "script.py")
	code := "import os\nprint(os.environ.get('MY_KEY'))\n"
	if err := os.WriteFile(p, []byte(code), 0600); err != nil {
		t.Fatal(err)
	}
	args, _ := json.Marshal(map[string]string{"file": p})
	state := gateState("python", args, &turn{}, nil)
	if state["file_source"] != code || state["file_source_truncated"] != false {
		t.Fatalf("file source was not included in gate state: %#v", state)
	}

	// Do not send an unbounded script to the decision endpoint.
	if err := os.WriteFile(p, []byte(strings.Repeat("x", 32*1024)), 0600); err != nil {
		t.Fatal(err)
	}
	state = gateState("python", args, &turn{}, nil)
	if len(state["file_source"].(string)) != 16*1024 || state["file_source_truncated"] != true {
		t.Fatalf("large source not bounded: length=%d truncated=%v", len(state["file_source"].(string)), state["file_source_truncated"])
	}

	protected, _ := json.Marshal(map[string]string{"file": "/etc/ssh/ssh_host_ed25519_key"})
	state = gateState("python", protected, &turn{}, nil)
	if state["file_source_blocked"] != true || state["file_source"] != nil {
		t.Fatalf("protected script path was read into the decision request: %#v", state)
	}
}
