package main

import (
	"os"
	"path/filepath"
	"strings"
	"testing"

	"boers.email/yap/agent/llm"
)

func TestUserPartsImage(t *testing.T) {
	path := filepath.Join(t.TempDir(), "photo with space.png")
	if err := os.WriteFile(path, append([]byte("\x89PNG\r\n\x1a\n"), make([]byte, 32)...), 0o600); err != nil {
		t.Fatal(err)
	}
	text := "What is this?\n![FILE: photo with space.png](file://" + strings.ReplaceAll(path, " ", "%20") + ")\nPlease be brief."
	parts, err := userParts(text)
	if err != nil {
		t.Fatal(err)
	}
	if len(parts) != 3 || parts[0].Text != "What is this?\n" || parts[1].Type != llm.PartImage || !strings.HasPrefix(parts[1].URL, "data:image/png;base64,") || parts[2].Text != "\nPlease be brief." {
		t.Fatalf("wrong parts: %+v", parts)
	}
	if parts, err := userParts("plain /tmp/photo.png and ![ordinary](file:///tmp/photo.png)"); err != nil || len(parts) != 1 || parts[0].Type != llm.PartText {
		t.Fatalf("ordinary text became image: %+v, %v", parts, err)
	}
	if err := os.Remove(path); err != nil {
		t.Fatal(err)
	}
	if _, err := userParts(text); err == nil {
		t.Fatal("missing attachment should fail")
	}
}

func TestUserPartsRejectsNonImageAndOversize(t *testing.T) {
	path := filepath.Join(t.TempDir(), "bad.png")
	for _, data := range [][]byte{[]byte("not an image"), make([]byte, maxImageBytes+1)} {
		if err := os.WriteFile(path, data, 0o600); err != nil {
			t.Fatal(err)
		}
		if _, err := userParts("![FILE: bad.png](file://" + path + ")"); err == nil {
			t.Fatal("invalid attachment should fail")
		}
	}
}
