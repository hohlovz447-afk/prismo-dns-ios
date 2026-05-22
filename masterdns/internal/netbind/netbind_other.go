//go:build !darwin && !ios

package netbind

import "net"

// On non-Darwin builds interface binding is a no-op; outbound UDP follows
// the OS default route. The iOS routing-loop problem this package solves
// does not exist outside iOS.
func dialUDPBound(network string, raddr *net.UDPAddr, _ string) (*net.UDPConn, error) {
	return net.DialUDP(network, nil, raddr)
}
