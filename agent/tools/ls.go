package tools

import (
	"os"
	"sort"
	"strings"
)

type lsArgs struct {
	Path string `json:"path,omitempty" jsonschema:"description=directory to list (default: current working directory)"`
}

func init() {
	Register("ls",
		"List entries of a directory (directories end with /). Use an absolute path.",
		func(a *lsArgs) (string, string, error) {
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
		})
}
