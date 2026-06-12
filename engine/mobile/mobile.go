// Package mobile exposes a narrow, gomobile-bindable surface for the
// PrismoVPN client. Used by the Prismo iOS / macOS app.
package mobile

import (
	"context"
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"runtime/debug"
	"sync"

	"prismo-dns-go/internal/client"
	"prismo-dns-go/internal/config"
	"prismo-dns-go/internal/netbind"
)

// SetBoundInterface tells the Go client to bind every subsequent outbound
// UDP socket (DNS-tunnel queries, MTU probes) to the named BSD interface
// (e.g. "en0", "pdp_ip0"). Empty string clears the binding.
//
// On iOS this is the fix for the "tunnel collapses when a consumer SOCKS
// app is active" routing loop: a third-party VPN app's NetworkExtension
// captures every non-loopback packet, including our outbound DNS queries,
// and ricochets them back through our own SOCKS5 listener. Pinning the
// socket to a physical interface bypasses the kernel's default route
// table that the NetworkExtension hooks into.
func SetBoundInterface(name string) {
	netbind.SetInterface(name)
}

// SetBoundAddress records the primary IPv4 and IPv6 source addresses of
// the active physical interface. The Go client uses these as the LocalAddr
// for outbound dials, in addition to setsockopt(IP_BOUND_IF). Belt-and-
// braces: IP_BOUND_IF picks the egress interface, and source-IP binding
// stops the foreign NetworkExtension from rewriting the route based on a
// default route it owns. Pass empty strings to clear.
func SetBoundAddress(ipv4, ipv6 string) {
	netbind.SetAddress(ipv4, ipv6)
}

// BoundInterface returns the currently configured BSD interface name, or
// "" if no binding is active.
func BoundInterface() string {
	return netbind.Current()
}

// BoundIPv4 returns the currently bound primary IPv4 address, or "".
func BoundIPv4() string {
	return netbind.CurrentIPv4()
}

// BoundIPv6 returns the currently bound primary IPv6 address, or "".
func BoundIPv6() string {
	return netbind.CurrentIPv6()
}

// LogWriter receives one log line at a time (no trailing newline).
type LogWriter interface {
	WriteLog(line string)
}

var (
	mu         sync.Mutex
	cancelFn   context.CancelFunc
	runningWG  sync.WaitGroup
	stdoutPump *stdoutInterceptor
	writerRef  LogWriter
)

// SetLogWriter installs a writer that will receive both stdout lines emitted
// by the Go client (logger, banners) and any error/diagnostic messages from
// this shim. Pass nil to disable forwarding.
func SetLogWriter(w LogWriter) {
	mu.Lock()
	defer mu.Unlock()
	writerRef = w
}

// IsRunning reports whether a Start call is currently active.
func IsRunning() bool {
	mu.Lock()
	defer mu.Unlock()
	return cancelFn != nil
}

// Start launches the PrismoVPN client with the given TOML config and
// newline-delimited resolver list. runtimeDir is a writable directory where
// transient files (config copies, dns cache) will live.
//
// Returns immediately once the client has been bootstrapped. The tunnel
// continues running in a background goroutine until Stop is called.
func Start(configTOML, resolversText, runtimeDir string) error {
	mu.Lock()
	if cancelFn != nil {
		mu.Unlock()
		return errors.New("client already running")
	}
	mu.Unlock()

	if runtimeDir == "" {
		return errors.New("runtimeDir is required")
	}
	if err := os.MkdirAll(runtimeDir, 0o755); err != nil {
		return fmt.Errorf("create runtime dir: %w", err)
	}

	configPath := filepath.Join(runtimeDir, "client_config.toml")
	resolversPath := filepath.Join(runtimeDir, "client_resolvers.txt")
	if err := os.WriteFile(configPath, []byte(configTOML), 0o600); err != nil {
		return fmt.Errorf("write client_config.toml: %w", err)
	}
	if err := os.WriteFile(resolversPath, []byte(resolversText), 0o600); err != nil {
		return fmt.Errorf("write client_resolvers.txt: %w", err)
	}

	pump := newStdoutInterceptor(func(line string) {
		mu.Lock()
		w := writerRef
		mu.Unlock()
		if w != nil {
			w.WriteLog(line)
		}
	})
	if err := pump.start(); err != nil {
		return fmt.Errorf("install stdout interceptor: %w", err)
	}

	overrides := config.ClientConfigOverrides{Values: map[string]any{}}
	app, err := client.Bootstrap(configPath, "", overrides)
	if err != nil {
		pump.stop()
		return fmt.Errorf("bootstrap: %w", err)
	}

	ctx, cancel := context.WithCancel(context.Background())

	mu.Lock()
	cancelFn = cancel
	stdoutPump = pump
	mu.Unlock()

	runningWG.Add(1)
	go func() {
		defer runningWG.Done()
		defer app.Cleanup()
		defer func() {
			if r := recover(); r != nil {
				emit(fmt.Sprintf("client panic: %v\n%s", r, debug.Stack()))
			}
		}()
		if err := app.Run(ctx); err != nil {
			emit(fmt.Sprintf("client runtime error: %v", err))
		}
	}()

	if name := netbind.Current(); name != "" {
		v4 := netbind.CurrentIPv4()
		v6 := netbind.CurrentIPv6()
		switch {
		case v4 != "" && v6 != "":
			emit("Bound outbound interface: " + name + " (src " + v4 + " / " + v6 + ")")
		case v4 != "":
			emit("Bound outbound interface: " + name + " (src " + v4 + ")")
		case v6 != "":
			emit("Bound outbound interface: " + name + " (src " + v6 + ")")
		default:
			emit("Bound outbound interface: " + name + " (no source IP yet)")
		}
	} else {
		emit("Bound outbound interface: none (default route)")
	}
	emit("Prismo tunnel started.")
	return nil
}

// Stop signals the running client to exit and waits briefly for shutdown.
// Safe to call when the client is not running.
func Stop() {
	mu.Lock()
	cancel := cancelFn
	pump := stdoutPump
	cancelFn = nil
	stdoutPump = nil
	mu.Unlock()

	if cancel == nil {
		return
	}
	cancel()
	runningWG.Wait()
	if pump != nil {
		pump.stop()
	}
	emit("Prismo tunnel stopped.")
}

func emit(line string) {
	mu.Lock()
	w := writerRef
	mu.Unlock()
	if w != nil {
		w.WriteLog(line)
	}
}
