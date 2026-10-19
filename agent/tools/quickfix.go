package tools

import (
	"fmt"

	"boers.email/yap/agent/utils"
)

type quickfixEntry struct {
	File   string `json:"file" jsonschema:"description=file path"`
	Line   int    `json:"line" jsonschema:"description=1-based line number,minimum=1"`
	Column int    `json:"column,omitempty" jsonschema:"description=1-based column number,minimum=1"`
	Text   string `json:"text" jsonschema:"description=message shown in the quickfix list"`
}

type quickfixArgs struct {
	Entries []quickfixEntry `json:"entries" jsonschema:"description=entries that replace the current quickfix list,minItems=1"`
}

func init() {
	Register("quickfix",
		"Replace the current Neovim quickfix list with these source locations. Previous lists remain available via :colder.",
		func(a *quickfixArgs) (string, string, error) {
			// A frontend side effect: emit the quickfix frame so the Lua side
			// replaces the list. The audit tool_call/tool_result events still
			// carry the full record; this is the UI action only.
			utils.EmitQuickfix(a.Entries)
			return fmt.Sprintf("quickfix list set (%d entries)", len(a.Entries)), "", nil
		})
}
