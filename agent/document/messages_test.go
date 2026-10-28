package document

import (
	"encoding/json"
	"os"
	"reflect"
	"strings"
	"testing"
)

// TestMessagesContract locks Messages against the shared fixture, and through
// it against structure.lua's messages_from (see
// tests/yap_transcript_messages_conformance_test.lua). The cases exercise the
// send-path rules that historically drifted: tool flattening, marker
// stripping, adjacent-role merging, empty-drop and unclosed-region recovery.
func TestMessagesContract(t *testing.T) {
	b, err := os.ReadFile("../../tests/transcript_messages_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []struct {
		Name     string    `json:"name"`
		Text     string    `json:"text"`
		Messages []Message `json:"messages"`
	}
	if err := json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	if len(cases) == 0 {
		t.Fatal("messages conformance fixture is empty")
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			got := Messages(c.Text)
			if !reflect.DeepEqual(got, c.Messages) {
				t.Fatalf("Messages(%q) mismatch:\n got: %#v\nwant: %#v", c.Text, got, c.Messages)
			}
		})
	}
}

func TestDecodeToolHeader(t *testing.T) {
	// Single-line header.
	lines := []string{
		"# @assistant",
		`<!-- yap:tool {"id":"t1","name":"read","arguments":{"path":"/x"}} -->`,
		"result",
		"<!-- /yap:tool -->",
	}
	doc := Parse(strings.Join(lines, "\n"))
	if len(doc.Regions) != 1 {
		t.Fatalf("regions = %+v", doc.Regions)
	}
	h := DecodeToolHeader(doc.Lines, doc.Regions[0])
	if h == nil || h.ID != "t1" || h.Name != "read" {
		t.Fatalf("header = %+v", h)
	}

	// Multi-line header: the pretty-printed arguments compact on decode.
	ml := []string{
		"# @assistant",
		"<!-- yap:tool",
		"{",
		`  "id": "t",`,
		`  "name": "write",`,
		`  "arguments": {`,
		`    "path": "/x"`,
		"  }",
		"}",
		"-->",
		"result",
		"<!-- /yap:tool -->",
	}
	doc2 := Parse(strings.Join(ml, "\n"))
	h2 := DecodeToolHeader(doc2.Lines, doc2.Regions[0])
	if h2 == nil || h2.Name != "write" || flattenArgs(h2.Arguments) != `{"path":"/x"}` {
		t.Fatalf("multi-line header = %+v, args = %q", h2, flattenArgs(h2.Arguments))
	}
}
