package document

import (
	"encoding/json"
	"fmt"
	"os"
	"reflect"
	"strings"
	"testing"
)

type fixture struct {
	Name        string    `json:"name"`
	Text        string    `json:"text"`
	Headings    []Heading `json:"headings"`
	Regions     []Region  `json:"regions"`
	Frontmatter int       `json:"frontmatter"`
}

func TestTranscriptContract(t *testing.T) {
	b, err := os.ReadFile("../../tests/transcript_cases.json")
	if err != nil {
		t.Fatal(err)
	}
	var cases []fixture
	if err = json.Unmarshal(b, &cases); err != nil {
		t.Fatal(err)
	}
	for _, c := range cases {
		t.Run(c.Name, func(t *testing.T) {
			got := Parse(c.Text)
			if !reflect.DeepEqual(got.Headings, c.Headings) || !reflect.DeepEqual(got.Regions, c.Regions) || got.Frontmatter != c.Frontmatter {
				t.Fatalf("got headings=%+v regions=%+v frontmatter=%d", got.Headings, got.Regions, got.Frontmatter)
			}
		})
	}
}
func BenchmarkParseTranscript(b *testing.B) {
	text := "---\ntitle: benchmark\n---\n"
	for i := 0; i < 1000; i++ {
		text += "# @user\nQuestion\n# @assistant\nAnswer\n<!-- yap:tool {} -->\nresult\n<!-- /yap:tool -->\n"
	}
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		Parse(text)
	}
}

// realisticTranscript builds a session-shaped document: frontmatter, then
// alternating user/assistant turns with a fenced tool region per reply.
func realisticTranscript(turns int) string {
	var sb strings.Builder
	sb.WriteString("---\ntitle: bench\nprovider: openai\nmodel: m1\n---\n")
	for i := 0; i < turns; i++ {
		sb.WriteString("# @user\n")
		fmt.Fprintf(&sb, "Investigate the session parser and navigation for issue %d.\n", i)
		sb.WriteString("\n# @assistant\n")
		fmt.Fprintf(&sb, "<!-- yap:tool {\"id\":\"t%d\",\"name\":\"read\",\"arguments\":{\"path\":\"/tmp/x\"}} -->\n", i)
		sb.WriteString("Here is a representative result line with some prose to parse.\n```\n")
		fmt.Fprintf(&sb, "def f(x):\n    return x + %d\n```\n<!-- /yap:tool -->\n\n", i)
	}
	return sb.String()
}

func BenchmarkParseRealistic(b *testing.B) {
	for _, turns := range []int{1000, 5000, 10000} {
		text := realisticTranscript(turns)
		b.Run(fmt.Sprintf("turns=%d", turns), func(b *testing.B) {
			b.SetBytes(int64(len(text)))
			b.ReportAllocs()
			for i := 0; i < b.N; i++ {
				Parse(text)
			}
		})
	}
}
