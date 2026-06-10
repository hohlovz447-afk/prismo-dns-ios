module prismo-singbox-go

go 1.25.0

require (
	github.com/sagernet/sing-box v1.11.4
	golang.org/x/mobile v0.0.0-20250606033058-aef2b8f56be9
)

// `go mod tidy` (run in CI) resolves the matching github.com/sagernet/sing
// version and all other transitive dependencies. golang.org/x/mobile is
// pinned via tools.go so `gomobile bind` finds it in the module graph.
