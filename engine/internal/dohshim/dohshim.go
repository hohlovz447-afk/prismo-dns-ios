// ==============================================================================
// PrismoVPN
// Package dohshim runs an in-process DNS-over-HTTPS forwarder.
//
// Why this exists:
// Under strict mobile "white-list" captivity (e.g. Tele2 home), the operator
// blocks UDP/53 and TCP/443 to every IP except a handful of whitelisted
// services (Yandex AS13238). The DNS tunnel therefore cannot reach a public
// recursive resolver over plain UDP. But Yandex runs a public DoH resolver
// (https://common.dot.dns.yandex.net/dns-query, 77.88.8.1) on whitelisted IPs,
// and that resolver recursively resolves our tunnel domain just like 8.8.8.8.
//
// Rather than rewrite the engine's UDP-socket hot path, this shim exposes a
// LOCAL UDP resolver (127.0.0.1:PORT). The tunnel engine treats it as an
// ordinary resolver — zero changes to the balancer / async runtime / MTU code.
// Each query the engine sends to 127.0.0.1:PORT is forwarded by the shim as an
// HTTP/2 POST (application/dns-message) to the whitelisted DoH upstream, and
// the wire-format response is written straight back to the engine.
//
// Outbound HTTPS is dialed through internal/netbind so it bypasses any
// third-party iOS NetworkExtension exactly like the UDP tunnel sockets.
// ==============================================================================

package dohshim

import (
	"bytes"
	"context"
	"crypto/tls"
	"errors"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync"
	"sync/atomic"
	"time"

	"prismo-dns-go/internal/netbind"
)

// Upstream describes a single DoH endpoint.
type Upstream struct {
	// URL is the full DoH endpoint, e.g. "https://common.dot.dns.yandex.net/dns-query".
	URL string
	// IP, when set, pins the TCP dial target (the URL host is only used for the
	// HTTP Host header and TLS SNI). Recommended under white-list so we never
	// depend on resolving the upstream hostname through a blocked resolver.
	IP string
	// SNI overrides the TLS server name. Defaults to the URL host.
	SNI string
	// Insecure skips TLS certificate verification (needed for our self-signed
	// fallback gateway; leave false for Yandex).
	Insecure bool
}

// Shim is a running local UDP->DoH forwarder.
type Shim struct {
	conn     *net.UDPConn
	client   *http.Client
	url      string
	maxConc  chan struct{}
	logf     func(string, ...interface{})
	closed   atomic.Bool
	wg       sync.WaitGroup
	reqTimeout time.Duration
}

const (
	maxDNSMessage   = 65535
	defaultTimeout  = 12 * time.Second
	defaultMaxConc  = 256
)

// Start launches the shim. It binds a local UDP socket on 127.0.0.1 and returns
// the shim plus its "127.0.0.1:port" address to register as a resolver.
func Start(up Upstream, logf func(string, ...interface{})) (*Shim, string, error) {
	if logf == nil {
		logf = func(string, ...interface{}) {}
	}
	if up.URL == "" {
		return nil, "", errors.New("dohshim: empty upstream URL")
	}

	laddr := &net.UDPAddr{IP: net.IPv4(127, 0, 0, 1), Port: 0}
	conn, err := net.ListenUDP("udp", laddr)
	if err != nil {
		return nil, "", fmt.Errorf("dohshim: listen: %w", err)
	}

	sni := up.SNI
	if sni == "" {
		if host, _, e := splitURLHostPort(up.URL); e == nil {
			sni = host
		}
	}

	transport := &http.Transport{
		ForceAttemptHTTP2:     true,
		MaxIdleConns:          64,
		MaxIdleConnsPerHost:   64,
		IdleConnTimeout:       90 * time.Second,
		TLSHandshakeTimeout:   10 * time.Second,
		ExpectContinueTimeout: time.Second,
		TLSClientConfig: &tls.Config{
			ServerName:         sni,
			InsecureSkipVerify: up.Insecure,
			NextProtos:         []string{"h2", "http/1.1"},
		},
		DialContext: func(ctx context.Context, network, addr string) (net.Conn, error) {
			dialAddr := addr
			if up.IP != "" {
				_, port, e := net.SplitHostPort(addr)
				if e != nil {
					port = "443"
				}
				dialAddr = net.JoinHostPort(up.IP, port)
			}
			return netbind.DialTCPContext(ctx, "tcp", dialAddr)
		},
	}

	s := &Shim{
		conn:       conn,
		client:     &http.Client{Transport: transport, Timeout: defaultTimeout},
		url:        up.URL,
		maxConc:    make(chan struct{}, defaultMaxConc),
		logf:       logf,
		reqTimeout: defaultTimeout,
	}

	s.wg.Add(1)
	go s.readLoop()

	addr := conn.LocalAddr().String()
	logf("🔐 DoH shim active: %s -> %s (ip=%s sni=%s)", addr, up.URL, up.IP, sni)
	return s, addr, nil
}

// Addr returns the local "127.0.0.1:port" resolver address.
func (s *Shim) Addr() string {
	if s == nil || s.conn == nil {
		return ""
	}
	return s.conn.LocalAddr().String()
}

// Close stops the shim and releases the socket.
func (s *Shim) Close() {
	if s == nil || !s.closed.CompareAndSwap(false, true) {
		return
	}
	_ = s.conn.Close()
	s.wg.Wait()
	if s.client != nil {
		s.client.CloseIdleConnections()
	}
}

// OnNetworkChange drops idle HTTP/2 connections so the next DoH request
// re-dials and re-binds to the new physical interface (Wi-Fi <-> cellular).
func (s *Shim) OnNetworkChange() {
	if s == nil || s.client == nil {
		return
	}
	s.client.CloseIdleConnections()
}

func (s *Shim) readLoop() {
	defer s.wg.Done()
	for {
		buf := make([]byte, maxDNSMessage)
		n, src, err := s.conn.ReadFromUDP(buf)
		if err != nil {
			if s.closed.Load() {
				return
			}
			// transient read error; brief pause to avoid a tight spin
			time.Sleep(5 * time.Millisecond)
			continue
		}
		if n < 12 || src == nil {
			continue
		}
		query := make([]byte, n)
		copy(query, buf[:n])

		select {
		case s.maxConc <- struct{}{}:
		default:
			// Too many in-flight; drop. The engine's ARQ will resend.
			continue
		}
		s.wg.Add(1)
		go func(q []byte, dst *net.UDPAddr) {
			defer s.wg.Done()
			defer func() { <-s.maxConc }()
			resp, err := s.exchange(q)
			if err != nil || len(resp) < 2 {
				return
			}
			// Preserve the DNS transaction ID the engine expects.
			resp[0] = q[0]
			resp[1] = q[1]
			_ = s.conn.SetWriteDeadline(time.Now().Add(2 * time.Second))
			_, _ = s.conn.WriteToUDP(resp, dst)
		}(query, src)
	}
}

func (s *Shim) exchange(query []byte) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), s.reqTimeout)
	defer cancel()

	req, err := http.NewRequestWithContext(ctx, http.MethodPost, s.url, bytes.NewReader(query))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/dns-message")
	req.Header.Set("Accept", "application/dns-message")

	resp, err := s.client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		_, _ = io.Copy(io.Discard, io.LimitReader(resp.Body, 4096))
		return nil, fmt.Errorf("dohshim: upstream status %d", resp.StatusCode)
	}
	return io.ReadAll(io.LimitReader(resp.Body, maxDNSMessage))
}

// splitURLHostPort extracts the host (without scheme/path) from a DoH URL.
func splitURLHostPort(rawURL string) (string, string, error) {
	s := rawURL
	if i := indexOf(s, "://"); i >= 0 {
		s = s[i+3:]
	}
	if i := indexOf(s, "/"); i >= 0 {
		s = s[:i]
	}
	if host, port, err := net.SplitHostPort(s); err == nil {
		return host, port, nil
	}
	return s, "443", nil
}

func indexOf(s, sub string) int {
	return bytes.Index([]byte(s), []byte(sub))
}
