// Package dceskills embeds the root cli.yaml so cmd/dc/main.go can
// access it via a plain import without filesystem path traversal.
package dceskills

import _ "embed"

//go:embed cli.yaml
var CLIConfig []byte
