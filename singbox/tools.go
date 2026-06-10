//go:build tools

// Package tools pins golang.org/x/mobile in the module graph so `gomobile
// bind` works (gomobile requires it as a direct dependency of the module
// being bound). The build tag keeps it out of normal builds.
package tools

import (
	_ "golang.org/x/mobile/bind"
)
