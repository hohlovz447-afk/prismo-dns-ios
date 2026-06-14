// ==============================================================================
// PrismoVPN
// Author: Prismo
// Github: https://github.com/prismo
// Year: 2026
// ==============================================================================

package version

import "strings"

// BuildVersion is set at link-time using -ldflags "-X prismo-dns-go/internal/version.BuildVersion=..."
var BuildVersion = "dev"

// GetVersion returns the current build version.
func GetVersion() string {
	v := strings.TrimSpace(BuildVersion)
	if v == "" {
		return "dev"
	}
	return v
}
