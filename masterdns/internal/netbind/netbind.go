// Package netbind centralises outbound UDP dialing so every socket can be
// bound to a specific physical network interface (Darwin IP_BOUND_IF /
// IPV6_BOUND_IF). On iOS this bypasses any NetworkExtension VPN that another
// app on the device has installed, preventing the DNS-tunnel routing loop
// that otherwise collapses the MasterDnsVPN client.
package netbind

import (
	"net"
	"sync"
	"sync/atomic"
)

var (
	iface       atomic.Pointer[string]
	hooksMu     sync.Mutex
	hooks       = map[uint64]func(){}
	hookCounter uint64
)

// SetInterface records the BSD interface name (e.g. "en0", "pdp_ip0") that
// every subsequent DialUDP should bind its socket to. Pass "" to disable
// binding and fall back to the OS default route.
//
// If the effective name changes, all registered OnChange hooks fire so
// callers can drop cached sockets that are bound to the previous interface.
func SetInterface(name string) {
	prev := iface.Load()
	previous := ""
	if prev != nil {
		previous = *prev
	}
	if previous == name {
		return
	}
	copy := name
	iface.Store(&copy)
	fireHooks()
}

// Current returns the currently configured BSD interface name, or "" if
// no binding is configured.
func Current() string {
	p := iface.Load()
	if p == nil {
		return ""
	}
	return *p
}

// HookHandle identifies a callback previously installed via OnChange. Pass
// it to RemoveHook to unregister so the caller (typically a client.Client
// shutdown path) can avoid leaking references to stopped instances.
type HookHandle uint64

// OnChange registers a callback invoked whenever SetInterface receives a
// different name. Used by the MasterDnsVPN client to drop its UDP socket
// pool when the underlying physical link switches (e.g. Wi-Fi → cellular).
func OnChange(fn func()) HookHandle {
	if fn == nil {
		return 0
	}
	hooksMu.Lock()
	hookCounter++
	id := hookCounter
	hooks[id] = fn
	hooksMu.Unlock()
	return HookHandle(id)
}

// RemoveHook unregisters a previously installed OnChange callback. Safe to
// call with a zero handle (no-op).
func RemoveHook(h HookHandle) {
	if h == 0 {
		return
	}
	hooksMu.Lock()
	delete(hooks, uint64(h))
	hooksMu.Unlock()
}

func fireHooks() {
	hooksMu.Lock()
	snapshot := make([]func(), 0, len(hooks))
	for _, fn := range hooks {
		snapshot = append(snapshot, fn)
	}
	hooksMu.Unlock()
	for _, h := range snapshot {
		h()
	}
}

// DialUDP dials raddr over UDP and, if an interface name is configured,
// binds the resulting socket to that physical interface via setsockopt.
// With no interface configured it is exactly equivalent to net.DialUDP.
func DialUDP(network string, raddr *net.UDPAddr) (*net.UDPConn, error) {
	name := Current()
	if name == "" {
		return net.DialUDP(network, nil, raddr)
	}
	return dialUDPBound(network, raddr, name)
}
