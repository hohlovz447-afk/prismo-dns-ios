// ==============================================================================
// PrismoVPN
// Author: Prismo
// Github: https://github.com/prismo
// Year: 2026
// ==============================================================================
// Package client provides the core logic and initialization for the PrismoVPN client.
// This file (client.go) defines the main Client struct and bootstrapping process.
// ==============================================================================
package client

import (
	"context"
	"fmt"
	"net"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"prismo-dns-go/internal/arq"
	"prismo-dns-go/internal/config"
	dnsCache "prismo-dns-go/internal/dnscache"
	"prismo-dns-go/internal/dohshim"
	Enums "prismo-dns-go/internal/enums"
	fragmentStore "prismo-dns-go/internal/fragmentstore"
	"prismo-dns-go/internal/logger"
	"prismo-dns-go/internal/mlq"
	"prismo-dns-go/internal/netbind"
	"prismo-dns-go/internal/security"
	VpnProto "prismo-dns-go/internal/vpnproto"
)

const (
	EDnsSafeUDPSize = 4096
)

type Client struct {
	cfg      config.ClientConfig
	log      *logger.Logger
	codec    *security.Codec
	balancer *Balancer

	successMTUChecks  bool
	udpBufferPool     sync.Pool
	resolverConnsMu   sync.Mutex
	resolverConns     map[string]chan pooledUDPConn
	resolverAddrMu    sync.RWMutex
	resolverAddrCache map[string]*net.UDPAddr
	nowFn             func() time.Time

	// MTU States
	syncedUploadMTU                       int
	syncedDownloadMTU                     int
	syncedUploadChars                     int
	safeUploadMTU                         int
	maxPackedBlocks                       int
	uploadCompression                     uint8
	downloadCompression                   uint8
	mtuCryptoOverhead                     int
	mtuProbeCounter                       atomic.Uint32
	mtuTestRetries                        int
	mtuTestTimeout                        time.Duration
	mtuSaveToFile                         bool
	mtuServersFileName                    string
	mtuServersFileFormat                  string
	mtuSuccessOutputPath                  string
	mtuOutputMu                           sync.Mutex
	mtuUsageSeparatorWritten              bool
	mtuUsingSeparatorText                 string
	mtuRemovedServerLogFormat             string
	mtuAddedServerLogFormat               string
	mtuReactiveAddedServerLogFormat       string
	streamResolverFailoverResendThreshold int
	streamResolverFailoverCooldown        time.Duration

	// Session States
	sessionID             uint8
	sessionCookie         uint8
	responseMode          uint8
	sessionReady          bool
	initStateMu           sync.Mutex
	sessionInitReady      bool
	sessionInitBase64     bool
	sessionInitPayload    []byte
	sessionInitVerify     [4]byte
	sessionInitCursor     int
	sessionInitBusyUnix   atomic.Int64
	sessionResetPending   atomic.Bool
	runtimeResetPending   atomic.Bool
	resolverHealthStarted atomic.Bool
	sessionResetSignal    chan struct{}
	rxDroppedPackets      atomic.Uint64
	lastRXDropLogUnix     atomic.Int64

	// Async Runtime Workers & Channels
	asyncWG              sync.WaitGroup
	asyncCancel          context.CancelFunc
	tunnelConns          []*net.UDPConn
	plannerQueue         chan plannerTask
	encodedTXChannel     chan writerTask
	rxChannel            chan asyncReadPacket
	tunnelRX_TX_Workers  int
	tunnelProcessWorkers int
	tunnelPacketTimeout  time.Duration

	// Local Proxy Daemons
	tcpListener *TCPListener
	dnsListener *DNSListener

	// Stream Management
	streamsMu             sync.RWMutex
	active_streams        map[uint16]*Stream_client
	last_stream_id        uint16
	streamSetVersion      atomic.Uint64
	orphanQueue           *mlq.MultiLevelQueue[VpnProto.Packet]
	recentlyClosedMu      sync.Mutex
	recentlyClosedStreams map[uint16]time.Time
	recentlyClosedHeap    recentlyClosedHeap

	// Signals to wake up dispatcher and downstream stages.
	dispatchSignal          chan struct{}
	plannerQueueSpaceSignal chan struct{}
	writerQueueSpaceSignal  chan struct{}

	// Autonomous Ping Manager
	pingManager *PingManager

	// DNS Management
	localDNSCache          *dnsCache.Store
	dnsResponses           *fragmentStore.Store[dnsFragmentKey]
	localDNSCachePersist   bool
	localDNSCachePath      string
	localDNSCacheFlushTick time.Duration
	localDNSCacheLoadOnce  sync.Once
	localDNSCacheFlushOnce sync.Once

	// SOCKS5 brute-force rate limiter
	socksRateLimit *socksRateLimiter

	// netbind change-hook handle; drops the UDP socket pool when the device
	// switches physical interfaces (Wi-Fi ↔ cellular).
	netbindHook netbind.HookHandle

	// Optional in-process DoH forwarders (white-list bypass). When non-empty,
	// all tunnel DNS is routed through them via local 127.0.0.1 UDP resolvers,
	// one shim per upstream IP for parallel channels.
	dohShims []*dohshim.Shim
}

// clientStreamTXPacket represents a queued packet pending transmission or retransmission.
type clientStreamTXPacket struct {
	PacketType       uint8
	SequenceNum      uint16
	FragmentID       uint8
	TotalFragments   uint8
	CompressionType  uint8
	Payload          []byte
	CreatedAt        time.Time
	TTL              time.Duration
	LastSentAt       time.Time
	RetryDelay       time.Duration
	RetryAt          time.Time
	RetryCount       int
	Scheduled        bool
	isControlCounted atomic.Bool
}

type recentlyClosedEntry struct {
	streamID uint16
	expires  time.Time
}

type recentlyClosedHeap []recentlyClosedEntry

func (h recentlyClosedHeap) Len() int { return len(h) }

func (h recentlyClosedHeap) Less(i, j int) bool {
	return h[i].expires.Before(h[j].expires)
}

func (h recentlyClosedHeap) Swap(i, j int) { h[i], h[j] = h[j], h[i] }

func (h *recentlyClosedHeap) Push(x any) {
	*h = append(*h, x.(recentlyClosedEntry))
}

func (h *recentlyClosedHeap) Pop() any {
	old := *h
	n := len(old)
	item := old[n-1]
	*h = old[:n-1]
	return item
}

// plannerTask is the handoff between dispatcher and the planner/encoder stage.
// The dispatcher only decides fairness/dequeue/packing. Resolver selection and
// fan-out happen later in the encode stage.
type plannerTask struct {
	opts      VpnProto.BuildOptions
	dupCount  int
	wasPacked bool
	item      *clientStreamTXPacket
	selected  *Stream_client
}

type encodedOutboundDatagram struct {
	addr      *net.UDPAddr
	serverKey string
	packet    []byte
}

type writerTask struct {
	wasPacked bool
	item      *clientStreamTXPacket
	selected  *Stream_client
	frames    []encodedOutboundDatagram
}

// Bootstrap initializes a new Client by loading configuration, setting up logging,
// and preparing the connection map.
func Bootstrap(configPath string, logPath string, overrides config.ClientConfigOverrides) (*Client, error) {
	cfg, err := config.LoadClientConfigWithOverrides(configPath, overrides)
	if err != nil {
		return nil, err
	}
	return BootstrapLoadedConfig(cfg, logPath)
}

func BootstrapLoadedConfig(cfg config.ClientConfig, logPath string) (*Client, error) {
	var log *logger.Logger
	if logPath != "" {
		log = logger.NewWithFile("PrismoVPN Client", cfg.LogLevel, logPath)
	} else {
		log = logger.New("PrismoVPN Client", cfg.LogLevel)
	}

	codec, err := security.NewCodec(cfg.DataEncryptionMethod, cfg.EncryptionKey)
	if err != nil {
		return nil, fmt.Errorf("client codec setup failed: %w", err)
	}

	c := New(cfg, log, codec)
	c.enableDoHShimIfConfigured()
	if err := c.BuildConnectionMap(); err != nil {
		if c.log != nil {
			c.log.Errorf("<red>%v</red>", err)
		}
		return nil, err
	}
	return c, nil
}

// enableDoHShimIfConfigured starts the in-process DoH forwarder(s) when the
// config specifies a DoH upstream, and rewrites the resolver list to point
// exclusively at the shims' local 127.0.0.1 endpoints. Multiple upstream IPs
// (DOH_UPSTREAM_IPS, comma-separated) each get their own shim → the balancer
// gets several parallel DoH channels (e.g. Yandex's anycast IPs), which dodges
// per-connection rate limits and raises throughput. On any failure it logs and
// falls back to the normal UDP resolver list (non-fatal).
func (c *Client) enableDoHShimIfConfigured() {
	url := strings.TrimSpace(c.cfg.DoHUpstreamURL)
	if url == "" {
		return
	}

	// Build the list of upstream IPs to pin (one shim each).
	var ips []string
	if list := strings.TrimSpace(c.cfg.DoHUpstreamIPs); list != "" {
		for _, p := range strings.Split(list, ",") {
			if ip := strings.TrimSpace(p); ip != "" {
				ips = append(ips, ip)
			}
		}
	}
	if len(ips) == 0 {
		ips = append(ips, strings.TrimSpace(c.cfg.DoHUpstreamIP)) // may be "" → shim resolves host itself
	}

	sni := strings.TrimSpace(c.cfg.DoHUpstreamSNI)
	var resolvers []config.ResolverAddress
	resolverMap := map[string]int{}
	for _, ip := range ips {
		shim, addr, err := dohshim.Start(dohshim.Upstream{
			URL:      url,
			IP:       ip,
			SNI:      sni,
			Insecure: c.cfg.DoHInsecure,
		}, c.log.Infof)
		if err != nil {
			c.log.Warnf("⚠️ DoH shim start failed for ip=%q: %v", ip, err)
			continue
		}
		host, portStr, err := net.SplitHostPort(addr)
		if err != nil {
			shim.Close()
			continue
		}
		port, _ := strconv.Atoi(portStr)
		c.dohShims = append(c.dohShims, shim)
		resolvers = append(resolvers, config.ResolverAddress{IP: host, Port: port})
		resolverMap[host] = port
	}

	if len(c.dohShims) == 0 {
		c.log.Warnf("⚠️ DoH bypass disabled (no shim started) — using UDP resolvers")
		return
	}

	// Tunnel UDP now flows only to loopback; disable interface binding for UDP
	// (each shim's outbound HTTPS stays interface-bound via DialTCPContext).
	netbind.SetUDPUnbound(true)

	c.cfg.Resolvers = resolvers
	c.cfg.ResolverMap = resolverMap
	c.log.Infof("🔐 <green>DoH bypass active</green>: <yellow>%d</yellow> parallel channel(s) → <yellow>%s</yellow>", len(c.dohShims), url)
}

func New(cfg config.ClientConfig, log *logger.Logger, codec *security.Codec) *Client {
	var responseMode uint8
	if cfg.BaseEncodeData {
		responseMode = mtuProbeBase64Reply
	}

	c := &Client{
		cfg:                 cfg,
		log:                 log,
		codec:               codec,
		balancer:            NewBalancer(cfg.ResolverBalancingStrategy, log),
		uploadCompression:   uint8(cfg.UploadCompressionType),
		downloadCompression: uint8(cfg.DownloadCompressionType),
		mtuCryptoOverhead:   mtuCryptoOverhead(cfg.DataEncryptionMethod),
		maxPackedBlocks:     1,
		responseMode:        responseMode,
		udpBufferPool: sync.Pool{
			New: func() any {
				return make([]byte, RuntimeUDPReadBufferSize)
			},
		},
		resolverConns:                         make(map[string]chan pooledUDPConn),
		resolverAddrCache:                     make(map[string]*net.UDPAddr),
		mtuTestRetries:                        cfg.MTUTestRetries,
		mtuTestTimeout:                        time.Duration(cfg.MTUTestTimeout * float64(time.Second)),
		mtuSaveToFile:                         cfg.SaveMTUServersToFile,
		mtuServersFileName:                    cfg.MTUServersFileName,
		mtuServersFileFormat:                  cfg.MTUServersFileFormat,
		mtuUsingSeparatorText:                 cfg.MTUUsingSeparatorText,
		mtuRemovedServerLogFormat:             cfg.MTURemovedServerLogFormat,
		mtuAddedServerLogFormat:               cfg.MTUAddedServerLogFormat,
		mtuReactiveAddedServerLogFormat:       cfg.MTUReactiveAddedServerLogFormat,
		streamResolverFailoverResendThreshold: cfg.StreamResolverFailoverResendThreshold,
		streamResolverFailoverCooldown:        time.Duration(cfg.StreamResolverFailoverCooldownSec * float64(time.Second)),

		// Workers config
		tunnelRX_TX_Workers:     cfg.RX_TX_Workers,
		tunnelProcessWorkers:    cfg.TunnelProcessWorkers,
		tunnelPacketTimeout:     time.Duration(cfg.TunnelPacketTimeoutSec * float64(time.Second)),
		plannerQueue:            make(chan plannerTask, max(24, cfg.RX_TX_Workers*24)),
		encodedTXChannel:        make(chan writerTask, max(24, cfg.RX_TX_Workers*24)),
		rxChannel:               make(chan asyncReadPacket, cfg.EffectiveRXChannelSize()),
		active_streams:          make(map[uint16]*Stream_client),
		recentlyClosedStreams:   make(map[uint16]time.Time),
		recentlyClosedHeap:      make(recentlyClosedHeap, 0, 128),
		dispatchSignal:          make(chan struct{}, 1),
		plannerQueueSpaceSignal: make(chan struct{}, 1),
		writerQueueSpaceSignal:  make(chan struct{}, 1),

		// DNS Management
		localDNSCache: dnsCache.New(
			cfg.LocalDNSCacheMaxRecords,
			time.Duration(cfg.LocalDNSCacheTTLSeconds)*time.Second,
			time.Duration(cfg.LocalDNSPendingTimeoutSec)*time.Second,
		),
		dnsResponses:           fragmentStore.New[dnsFragmentKey](cfg.EffectiveDNSResponseFragmentStoreCap()),
		localDNSCachePersist:   cfg.LocalDNSCachePersist,
		localDNSCachePath:      cfg.LocalDNSCachePath(),
		localDNSCacheFlushTick: time.Duration(cfg.LocalDNSCacheFlushSec) * time.Second,
		orphanQueue:            mlq.New[VpnProto.Packet](cfg.EffectiveOrphanQueueInitialCapacity()),
		sessionResetSignal:     make(chan struct{}, 1),
		socksRateLimit:         newSocksRateLimiter(),
	}

	if c.streamResolverFailoverResendThreshold < 1 {
		c.streamResolverFailoverResendThreshold = 1
	}

	if c.streamResolverFailoverCooldown <= 0 {
		c.streamResolverFailoverCooldown = time.Second
	}

	// Drop cached UDP sockets whenever the bound physical interface changes,
	// so subsequent dials re-bind to the new interface index. If the async
	// runtime is active, restart it so its long-lived worker sockets are
	// recreated with the new binding too. The hook is removed in Cleanup().
	c.netbindHook = netbind.OnChange(c.handleNetbindChange)

	c.balancer.SetStreamFailoverConfig(c.streamResolverFailoverResendThreshold, c.streamResolverFailoverCooldown)
	c.balancer.SetAutoDisableConfig(
		cfg.AutoDisableTimeoutServers,
		time.Duration(cfg.AutoDisableTimeoutWindowSeconds*float64(time.Second)),
	)

	c.balancer.SetResolverDisabledHandler(func(conn *Connection, cause string) {
		c.appendMTURemovedServerLine(conn, cause)
	})

	c.balancer.SetResolverDownConfirmHandler(func(conn *Connection, window time.Duration) bool {
		return c.confirmResolverDown(conn, window)
	})

	c.pingManager = newPingManager(c)
	return c
}

func (c *Client) handleNetbindChange() {
	if c == nil {
		return
	}

	c.closeResolverConnPools()
	for _, s := range c.dohShims {
		s.OnNetworkChange()
	}
	if c.asyncCancel != nil {
		c.requestSessionRestart("bound physical interface changed")
	}
}

func (c *Client) nextSessionInitRetryDelay(failures int) time.Duration {
	if failures <= 0 {
		return 0
	}

	delay := c.cfg.SessionInitRetryBase()
	if failures > c.cfg.SessionInitRetryLinearAfter {
		delay += time.Duration(failures-c.cfg.SessionInitRetryLinearAfter) * c.cfg.SessionInitRetryStep()
	}

	if delay > c.cfg.SessionInitRetryMax() {
		return c.cfg.SessionInitRetryMax()
	}

	return delay
}

// Cleanup releases process-global resources associated with this client.
// Idempotent and safe to call after Run returns or on a never-started client.
func (c *Client) Cleanup() {
	if c == nil {
		return
	}
	if c.netbindHook != 0 {
		netbind.RemoveHook(c.netbindHook)
		c.netbindHook = 0
	}
	if len(c.dohShims) > 0 {
		for _, s := range c.dohShims {
			s.Close()
		}
		c.dohShims = nil
		netbind.SetUDPUnbound(false)
	}
}

// Run starts the main execution loop of the client.
func (c *Client) Run(ctx context.Context) error {
	c.successMTUChecks = false
	c.log.Infof("\U0001F504 <cyan>Starting main runtime loop...</cyan>")
	sessionInitRetryDelay := time.Duration(0)
	sessionInitRetryFailures := 0

	// Ensure local DNS cache is loaded from file if persistence is enabled
	c.ensureLocalDNSCacheLoaded()

	for {
		select {
		case <-ctx.Done():
			c.notifySessionCloseBurst(time.Second)
			c.StopAsyncRuntime()
			return nil
		default:
			if !c.successMTUChecks {
				if err := c.RunInitialMTUTests(ctx); err != nil {
					c.log.Errorf("<red>MTU tests failed: %v</red>", err)
					c.successMTUChecks = false
					// Wait a bit before retrying or exiting if critical
					select {
					case <-ctx.Done():
						c.notifySessionCloseBurst(time.Second)
						c.StopAsyncRuntime()
						return nil
					case <-time.After(5 * time.Second):
					}
					continue
				}

				if c.syncedUploadMTU <= 0 || c.syncedDownloadMTU <= 0 {
					c.successMTUChecks = false
					c.log.Errorf("<red>❌ MTU tests failed: Upload MTU: %d, Download MTU: %d</red>", c.syncedUploadMTU, c.syncedDownloadMTU)
					select {
					case <-ctx.Done():
						c.notifySessionCloseBurst(time.Second)
						c.StopAsyncRuntime()
						return nil
					case <-time.After(5 * time.Second):
					}
					continue
				}

				c.successMTUChecks = true
				if c.resolverHealthStarted.CompareAndSwap(false, true) {
					go c.runResolverHealthLoop(ctx)
				}
				c.ShortPrintBanner()
			}

			if !c.sessionReady {
				retries := c.cfg.MTUTestRetries
				if retries < 1 {
					retries = 3
				}

				if err := c.InitializeSession(retries); err != nil {
					sessionInitRetryFailures++
					sessionInitRetryDelay = c.nextSessionInitRetryDelay(sessionInitRetryFailures)
					c.log.Errorf("<red>❌ Session initialization failed: %v</red>", err)
					c.log.Warnf("<yellow>Session init retry backoff: %s</yellow>", sessionInitRetryDelay)
					select {
					case <-ctx.Done():
						c.notifySessionCloseBurst(time.Second)
						c.StopAsyncRuntime()
						return nil
					case <-time.After(sessionInitRetryDelay):
					}
					continue
				}
				c.log.Infof("<green>✅ Session Initialized Successfully (ID: <cyan>%d</cyan>)</green>", c.sessionID)

				sessionInitRetryFailures = 0
				sessionInitRetryDelay = 0
				if err := c.StartAsyncRuntime(ctx); err != nil {
					c.log.Errorf("<red>❌ Async Runtime failed to launch: %v</red>", err)
					return err
				}

				c.InitVirtualStream0()

				if c.pingManager != nil {
					c.pingManager.Start(ctx)
				}

				c.ensureLocalDNSCachePersistence(ctx)
			}

			select {
			case <-ctx.Done():
				c.notifySessionCloseBurst(time.Second)
				c.StopAsyncRuntime()
				return nil
			case <-c.sessionResetSignal:
				c.StopAsyncRuntime()
				c.resetSessionState(true)
				c.clearRuntimeResetRequest()
				sessionInitRetryFailures++
				sessionInitRetryDelay = c.nextSessionInitRetryDelay(sessionInitRetryFailures)
				c.log.Warnf("<yellow>Session reset requested, retrying in %s</yellow>", sessionInitRetryDelay)
				select {
				case <-ctx.Done():
					c.notifySessionCloseBurst(time.Second)
					c.StopAsyncRuntime()
					return nil
				case <-time.After(sessionInitRetryDelay):
				}
				continue
			case <-time.After(1 * time.Second):
			}
		}
	}
}

func (c *Client) HandleStreamPacket(packet VpnProto.Packet) error {
	if !packet.HasStreamID {
		return nil
	}

	c.streamsMu.RLock()
	s, ok := c.active_streams[packet.StreamID]
	c.streamsMu.RUnlock()

	if !ok || s == nil {
		return nil
	}

	arqObj, ok := s.Stream.(*arq.ARQ)
	if !ok {
		if (packet.PacketType == Enums.PACKET_STREAM_DATA ||
			packet.PacketType == Enums.PACKET_STREAM_RESEND ||
			packet.PacketType == Enums.PACKET_STREAM_DATA_NACK) && !c.isRecentlyClosedStream(packet.StreamID, c.now()) {
			c.enqueueOrphanReset(Enums.PACKET_STREAM_RST, packet.StreamID, 0)
		}
		return nil
	}

	switch packet.PacketType {
	case Enums.PACKET_STREAM_DATA, Enums.PACKET_STREAM_RESEND:
		if arqObj.IsClosed() {
			c.enqueueOrphanReset(Enums.PACKET_STREAM_RST, packet.StreamID, 0)
			return nil
		}

		if !s.TerminalSince().IsZero() {
			c.enqueueOrphanReset(Enums.PACKET_STREAM_RST, packet.StreamID, 0)
			return nil
		}

		if !arqObj.ReceiveData(packet.SequenceNum, packet.Payload) {
			return nil
		}

	case Enums.PACKET_STREAM_DATA_NACK:
		if arqObj.IsClosed() || !s.TerminalSince().IsZero() {
			return nil
		}

		if arqObj.HandleDataNack(packet.SequenceNum) {
			c.balancer.NoteStreamProgress(packet.StreamID)
		}
	case Enums.PACKET_STREAM_CONNECTED:
		return c.handleStreamConnected(packet, s, arqObj)
	case Enums.PACKET_STREAM_CONNECT_FAIL:
		return c.handleStreamConnectFail(packet, s, arqObj)
	case Enums.PACKET_STREAM_CLOSE_READ:
		arqObj.MarkCloseReadReceived()
	case Enums.PACKET_STREAM_CLOSE_WRITE:
		arqObj.MarkCloseWriteReceived()
	case Enums.PACKET_STREAM_RST:
		arqObj.MarkRstReceived()
		arqObj.Close("peer reset received", arq.CloseOptions{Force: true})
		s.MarkTerminal(time.Now())
		if s.StatusValue() != streamStatusCancelled {
			s.SetStatus(streamStatusTimeWait)
		}
	default:
		handledAck := arqObj.HandleAckPacket(packet.PacketType, packet.SequenceNum, packet.FragmentID)
		if handledAck {
			c.balancer.NoteStreamProgress(packet.StreamID)
		}
		if _, ok := Enums.GetPacketCloseStream(packet.PacketType); handledAck && ok {
			if s.StatusValue() == streamStatusCancelled || arqObj.IsClosed() {
				s.MarkTerminal(time.Now())
				if s.StatusValue() != streamStatusCancelled {
					s.SetStatus(streamStatusTimeWait)
				}
			}
		}
	}

	return nil
}

func (c *Client) HandleSessionReject(packet VpnProto.Packet) error {
	c.requestSessionRestart("session reject received")
	return nil
}

func (c *Client) HandleSessionBusy() error {
	c.requestSessionRestart("session busy received")
	return nil
}

func (c *Client) HandleErrorDrop(packet VpnProto.Packet) error {
	c.requestSessionRestart("error drop received")
	return nil
}

func (c *Client) HandleMTUResponse(packet VpnProto.Packet) error {
	return nil
}
