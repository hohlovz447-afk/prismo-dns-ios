// Package mobile — calibrate.go
//
// On-device resolver speed calibration support. Exposes a "session ready"
// signal and a real-throughput download probe that runs through the engine's
// local SOCKS5 listener, so the Swift side can measure the actual end-to-end
// tunnel speed for whichever resolver(s) are currently active.
package mobile

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"strconv"
	"time"
)

// SessionReady reports whether the running tunnel has an established session
// and can carry traffic. Returns false when nothing is running.
func SessionReady() bool {
	mu.Lock()
	c := activeClient
	mu.Unlock()
	if c == nil {
		return false
	}
	return c.SessionReady()
}

// MeasureDownloadBytesPerSec downloads from url through the local SOCKS5 proxy
// at socksAddr ("host:port"), reading up to maxBytes or until timeoutSeconds,
// and returns the measured throughput in bytes/second (0 on failure).
//
// TLS/HTTP are handled natively in Go; only the TCP dial is routed through the
// engine's SOCKS5 listener, so the result reflects the real end-to-end tunnel
// speed of whatever resolver(s) are currently active.
func MeasureDownloadBytesPerSec(socksAddr string, url string, maxBytes int, timeoutSeconds float64) int64 {
	if socksAddr == "" || url == "" {
		return 0
	}
	if maxBytes <= 0 {
		maxBytes = 8 * 1024 * 1024
	}
	if timeoutSeconds <= 0 {
		timeoutSeconds = 8
	}
	timeout := time.Duration(timeoutSeconds * float64(time.Second))

	transport := &http.Transport{
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			return socks5Dial(ctx, socksAddr, addr)
		},
		DisableKeepAlives:   true,
		TLSHandshakeTimeout: timeout,
	}
	httpClient := &http.Client{Transport: transport, Timeout: timeout}

	ctx, cancel := context.WithTimeout(context.Background(), timeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodGet, url, nil)
	if err != nil {
		return 0
	}
	req.Header.Set("User-Agent", "Mozilla/5.0")

	start := time.Now()
	resp, err := httpClient.Do(req)
	if err != nil {
		return 0
	}
	defer resp.Body.Close()
	if resp.StatusCode < 200 || resp.StatusCode >= 400 {
		return 0
	}

	buf := make([]byte, 64*1024)
	total := 0
	for total < maxBytes {
		if time.Since(start) >= timeout {
			break
		}
		n, rerr := resp.Body.Read(buf)
		total += n
		if rerr != nil {
			break
		}
	}

	elapsed := time.Since(start).Seconds()
	if elapsed <= 0 || total <= 0 {
		return 0
	}
	return int64(float64(total) / elapsed)
}

// socks5Dial opens a TCP connection to socksAddr, performs a SOCKS5 no-auth
// handshake, then issues CONNECT to targetAddr ("host:port"). The hostname is
// sent as a domain (ATYP=3) so the exit node resolves it.
func socks5Dial(ctx context.Context, socksAddr, targetAddr string) (net.Conn, error) {
	host, portStr, err := net.SplitHostPort(targetAddr)
	if err != nil {
		return nil, err
	}
	port, err := strconv.ParseUint(portStr, 10, 16)
	if err != nil {
		return nil, err
	}

	d := net.Dialer{}
	conn, err := d.DialContext(ctx, "tcp", socksAddr)
	if err != nil {
		return nil, err
	}
	if deadline, ok := ctx.Deadline(); ok {
		_ = conn.SetDeadline(deadline)
	}

	// Greeting: VER=5, 1 method, no-auth (0x00).
	if _, err := conn.Write([]byte{0x05, 0x01, 0x00}); err != nil {
		conn.Close()
		return nil, err
	}
	greet := make([]byte, 2)
	if _, err := io.ReadFull(conn, greet); err != nil {
		conn.Close()
		return nil, err
	}
	if greet[0] != 0x05 || greet[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("socks5: no-auth rejected (%d/%d)", greet[0], greet[1])
	}

	// CONNECT with domain ATYP.
	h := []byte(host)
	if len(h) > 255 {
		conn.Close()
		return nil, fmt.Errorf("socks5: host too long")
	}
	reqPkt := make([]byte, 0, 7+len(h))
	reqPkt = append(reqPkt, 0x05, 0x01, 0x00, 0x03, byte(len(h)))
	reqPkt = append(reqPkt, h...)
	reqPkt = append(reqPkt, byte(port>>8), byte(port&0xff))
	if _, err := conn.Write(reqPkt); err != nil {
		conn.Close()
		return nil, err
	}

	// Reply: VER REP RSV ATYP + bound address (drained).
	hdr := make([]byte, 4)
	if _, err := io.ReadFull(conn, hdr); err != nil {
		conn.Close()
		return nil, err
	}
	if hdr[1] != 0x00 {
		conn.Close()
		return nil, fmt.Errorf("socks5: CONNECT failed (code %d)", hdr[1])
	}
	var skip int
	switch hdr[3] {
	case 0x01:
		skip = 4 + 2
	case 0x03:
		l := make([]byte, 1)
		if _, err := io.ReadFull(conn, l); err != nil {
			conn.Close()
			return nil, err
		}
		skip = int(l[0]) + 2
	case 0x04:
		skip = 16 + 2
	default:
		conn.Close()
		return nil, fmt.Errorf("socks5: bad ATYP %d", hdr[3])
	}
	if skip > 0 {
		if _, err := io.ReadFull(conn, make([]byte, skip)); err != nil {
			conn.Close()
			return nil, err
		}
	}

	_ = conn.SetDeadline(time.Time{})
	return conn, nil
}
