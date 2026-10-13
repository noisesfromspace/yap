package tools

import (
	"os"
	"path/filepath"
	"strings"
	"testing"
)

func TestWriteCreatesFileAndParents(t *testing.T) {
	dir := t.TempDir()
	p := filepath.Join(dir, "a", "b", "f.txt")

	r, ui, err := run(t, "write", `{"path":"`+p+`","content":"hello world\n"}`)
	if err != nil {
		t.Fatalf("write: %v", err)
	}
	if !strings.Contains(r, "Successfully wrote") {
		t.Fatalf("result: %q", r)
	}
	if ui == "" {
		t.Fatal("expected a unified diff in the ui payload")
	}
	data, err := os.ReadFile(p)
	if err != nil || string(data) != "hello world\n" {
		t.Fatalf("content: %q %v", data, err)
	}
}

func TestWriteOverwrites(t *testing.T) {
	p := filepath.Join(t.TempDir(), "f.txt")
	if _, _, err := run(t, "write", `{"path":"`+p+`","content":"first"}`); err != nil {
		t.Fatal(err)
	}
	if _, _, err := run(t, "write", `{"path":"`+p+`","content":"second"}`); err != nil {
		t.Fatal(err)
	}
	data, _ := os.ReadFile(p)
	if string(data) != "second" {
		t.Fatalf("content: %q", data)
	}
}
