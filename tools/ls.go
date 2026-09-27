package tools

import (
	"encoding/json"
	"os"
	"sort"
	"strings"
)

func init() {
	Register(&Tool{
		Name:        "ls",
		Description: "List entries of a directory (directories end with /). Use an absolute path.",
		Schema: `{"type":"object","properties":{
			"path":{"type":"string","description":"directory to list (default: current working directory)"}}}`,
		Run: func(args json.RawMessage) (string, string, error) {
			var a struct {
				Path string `json:"path"`
			}
			json.Unmarshal(args, &a)
			dir := a.Path
			if dir == "" {
				dir = "."
			}
			entries, err := os.ReadDir(dir)
			if err != nil {
				return "", "", err
			}
			names := make([]string, 0, len(entries))
			for _, e := range entries {
				n := e.Name()
				if e.IsDir() {
					n += "/"
				}
				names = append(names, n)
			}
			sort.Strings(names)
			return strings.Join(names, "\n"), "", nil
		},
	})
}
