//go:build darwin || ios

package netbind

import (
	"context"
	"errors"
	"net"
	"syscall"

	"golang.org/x/sys/unix"
)

func dialUDPBound(network string, raddr *net.UDPAddr, ifname string) (*net.UDPConn, error) {
	iface, err := net.InterfaceByName(ifname)
	if err != nil {
		return nil, err
	}
	idx := iface.Index

	d := net.Dialer{
		Control: func(_ string, _ string, c syscall.RawConn) error {
			var setErr error
			ctrlErr := c.Control(func(fd uintptr) {
				if e := unix.SetsockoptInt(int(fd), unix.IPPROTO_IP, unix.IP_BOUND_IF, idx); e != nil {
					setErr = e
					return
				}
				// IPv6 variant is harmless on a v4 socket but required when
				// the resolver address happens to be IPv6.
				if e := unix.SetsockoptInt(int(fd), unix.IPPROTO_IPV6, unix.IPV6_BOUND_IF, idx); e != nil {
					// Some kernels reject this on a v4 socket — non-fatal.
					_ = e
				}
			})
			if ctrlErr != nil {
				return ctrlErr
			}
			return setErr
		},
	}

	conn, err := d.DialContext(context.Background(), network, raddr.String())
	if err != nil {
		return nil, err
	}
	udp, ok := conn.(*net.UDPConn)
	if !ok {
		_ = conn.Close()
		return nil, errors.New("netbind: dialer returned non-UDP connection")
	}
	return udp, nil
}
