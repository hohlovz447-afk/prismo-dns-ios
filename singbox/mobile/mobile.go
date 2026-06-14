// Package mobile exposes a narrow, gomobile-bindable surface that runs a
// sing-box instance from a JSON config string. Used by the Prismo iOS app's
// "Speed" mode (regular VLESS servers).
//
// The Swift side builds the sing-box JSON (a socks inbound on 127.0.0.1 + a
// vless outbound) via VlessConfigBuilder, passes it to Start, and routes
// traffic through the local socks proxy (and, with a Network Extension, the
// system tun).
//
// The package is named `singbox` (not `mobile`) so gomobile generates
// Singbox-prefixed symbols (SingboxStart, SingboxLogWriterProtocol, ...) and
// avoids colliding with the existing Mobile.xcframework (Prismo core).
package singbox

import (
	"context"
	"sync"

	box "github.com/sagernet/sing-box"
	"github.com/sagernet/sing-box/include"
	"github.com/sagernet/sing-box/option"
)

var (
	mu       sync.Mutex
	instance *box.Box
	cancel   context.CancelFunc
)

// LogWriter mirrors the Swift-side log relay so sing-box logs can surface in
// the app log view. gomobile binds this as a protocol.
type LogWriter interface {
	WriteLog(line string)
}

// Start boots a sing-box instance from the given JSON config. Returns an error
// if a parse/start fails. Calling Start while already running stops the old
// instance first.
func Start(configJSON string, _ LogWriter) error {
	mu.Lock()
	defer mu.Unlock()

	if instance != nil {
		stopLocked()
	}

	// box.Context injects the protocol registries (inbound/outbound/endpoint)
	// so both config parsing and box.New are registry-aware. (v1.11.x takes
	// three registries; include.Context only exists in newer releases.)
	ctx, c := context.WithCancel(context.Background())
	ctx = box.Context(ctx, include.InboundRegistry(), include.OutboundRegistry(), include.EndpointRegistry())

	// option.Options exposes a context-aware unmarshal that wires up the
	// registries injected above; this is stable across sing-box versions.
	var opts option.Options
	if err := opts.UnmarshalJSONContext(ctx, []byte(configJSON)); err != nil {
		c()
		return err
	}

	b, err := box.New(box.Options{
		Context: ctx,
		Options: opts,
	})
	if err != nil {
		c()
		return err
	}

	if err := b.Start(); err != nil {
		c()
		_ = b.Close()
		return err
	}

	instance = b
	cancel = c
	return nil
}

// Stop tears down the running instance, if any.
func Stop() {
	mu.Lock()
	defer mu.Unlock()
	stopLocked()
}

func stopLocked() {
	if cancel != nil {
		cancel()
		cancel = nil
	}
	if instance != nil {
		_ = instance.Close()
		instance = nil
	}
}

// IsRunning reports whether an instance is currently active.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return instance != nil
}

// Version returns a static marker so the Swift side can confirm the framework
// is embedded.
func Version() string {
	return "prismo-singbox-1"
}
