import Foundation

#if canImport(Network)
import Network
#endif

#if canImport(Darwin)
import Darwin
#endif

#if canImport(Mobile)
import Mobile
#endif

// Watches the active physical network path and pushes both the BSD
// interface name AND the interface's own IPv4 address into the Go client
// (via MobileSetBoundInterface / MobileSetBoundAddress). The Go side then
// uses BOTH setsockopt(IP_BOUND_IF) and bind() to the local IP, which is
// the strongest combination for keeping outbound DNS traffic on the
// physical link when a third-party NetworkExtension (Happ / Shadowrocket)
// is active on the same device.
@MainActor
public final class PhysicalInterfaceMonitor: ObservableObject {
    public struct Snapshot: Equatable {
        public let name: String          // BSD name, e.g. "en0"
        public let type: InterfaceType
        public let ipv4: String          // e.g. "192.168.1.42" or ""
        public let ipv6: String          // first global v6, or "" (link-local skipped)
        public let foreignVPNActive: Bool // another app's NE is up alongside us
        public static let none = Snapshot(name: "", type: .none, ipv4: "", ipv6: "", foreignVPNActive: false)
    }

    public enum InterfaceType: String, Equatable {
        case wifi
        case cellular
        case wired
        case other
        case none
    }

    @Published public private(set) var snapshot: Snapshot = .none

    public var currentName: String { snapshot.name }
    public var currentIPv4: String { snapshot.ipv4 }
    public var currentIPv6: String { snapshot.ipv6 }
    public var foreignVPNActive: Bool { snapshot.foreignVPNActive }

    #if canImport(Network)
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "org.prismovpn.physical-interface")
    #endif
    private var started = false

    public init() {}

    public func start() {
        guard !started else { return }
        started = true

        #if canImport(Network)
        pathMonitor.pathUpdateHandler = { [weak self] path in
            guard let self else { return }
            let next = PhysicalInterfaceMonitor.resolveInterface(path: path)
            Task { @MainActor [weak self] in
                self?.apply(next)
            }
        }
        pathMonitor.start(queue: queue)
        #endif

        apply(PhysicalInterfaceMonitor.resolveFromGetifaddrs(preferring: nil, foreignVPN: false))
    }

    public func stop() {
        guard started else { return }
        started = false
        #if canImport(Network)
        pathMonitor.cancel()
        #endif
    }

    private func apply(_ next: Snapshot) {
        if next == snapshot { return }
        let previous = snapshot
        // Keep the latest snapshot for the currentIPv4/IPv6 getters, but only
        // re-bind the Go engine — which RESTARTS the tunnel session — when the
        // binding meaningfully changes. iOS rotates temporary IPv6 privacy
        // addresses (RFC 4941) every few minutes and NWPathMonitor fires often;
        // pushing those churned addresses would restart the session repeatedly
        // and the user sees the connection "drop every few minutes". So we
        // re-bind only on a real interface switch (name) or a primary-IPv4
        // change, and fall back to IPv6 only on a v6-only network.
        snapshot = next
        let bindingChanged: Bool
        if next.name != previous.name {
            bindingChanged = true
        } else if !next.ipv4.isEmpty || !previous.ipv4.isEmpty {
            bindingChanged = next.ipv4 != previous.ipv4
        } else {
            bindingChanged = next.ipv6 != previous.ipv6
        }
        if bindingChanged {
            push(next)
        }
    }

    private func push(_ snap: Snapshot) {
        #if canImport(Mobile)
        MobileSetBoundInterface(snap.name)
        MobileSetBoundAddress(snap.ipv4, snap.ipv6)
        #else
        _ = snap
        #endif
    }

    // MARK: - Resolution helpers

    #if canImport(Network)
    nonisolated static func resolveInterface(path: NWPath) -> Snapshot {
        // Detect a foreign VPN: NWPath reports interface type .other when
        // an NEPacketTunnelProvider is up. We only flag it when it appears
        // ALONGSIDE a real physical link, because the app itself never
        // installs an NE.
        let foreignVPN = path.usesInterfaceType(.other)

        guard path.status == .satisfied else {
            return resolveFromGetifaddrs(preferring: nil, foreignVPN: foreignVPN)
        }
        var preferredType: InterfaceType?
        if path.usesInterfaceType(.wiredEthernet) { preferredType = .wired }
        else if path.usesInterfaceType(.wifi) { preferredType = .wifi }
        else if path.usesInterfaceType(.cellular) { preferredType = .cellular }

        if let preferredType {
            let matching = path.availableInterfaces.first { iface in
                switch (preferredType, iface.type) {
                case (.wifi, .wifi), (.wired, .wiredEthernet), (.cellular, .cellular):
                    return true
                default:
                    return false
                }
            }
            if let name = matching?.name, !name.isEmpty {
                let (v4, v6) = addressesOfInterface(named: name)
                return Snapshot(name: name, type: preferredType, ipv4: v4, ipv6: v6, foreignVPNActive: foreignVPN)
            }
        }
        return resolveFromGetifaddrs(preferring: preferredType, foreignVPN: foreignVPN)
    }
    #endif

    nonisolated static func resolveFromGetifaddrs(preferring preferred: InterfaceType?, foreignVPN: Bool) -> Snapshot {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return .none }
        defer { freeifaddrs(head) }

        var seen: [(name: String, type: InterfaceType, score: Int)] = []
        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = node {
            defer { node = ptr.pointee.ifa_next }
            let name = String(cString: ptr.pointee.ifa_name)
            let flags = Int32(ptr.pointee.ifa_flags)
            let isUp = (flags & IFF_UP) != 0
            let isRunning = (flags & IFF_RUNNING) != 0
            let isLoopback = (flags & IFF_LOOPBACK) != 0
            guard isUp, isRunning, !isLoopback else { continue }
            if isVPNName(name) { continue }

            let type: InterfaceType
            let score: Int
            if name.hasPrefix("en") {
                type = .wifi
                score = 100
            } else if name.hasPrefix("pdp_ip") {
                type = .cellular
                score = 80
            } else if name.hasPrefix("eth") {
                type = .wired
                score = 90
            } else {
                type = .other
                score = 10
            }
            // Only keep interfaces that actually have an IPv4 or IPv6 address.
            let (v4, v6) = addressesOfInterface(named: name)
            guard !v4.isEmpty || !v6.isEmpty else { continue }
            seen.append((name, type, score))
        }

        if let preferred,
           let hit = seen.first(where: { $0.type == preferred }) {
            let (v4, v6) = addressesOfInterface(named: hit.name)
            return Snapshot(name: hit.name, type: hit.type, ipv4: v4, ipv6: v6, foreignVPNActive: foreignVPN)
        }
        if let best = seen.max(by: { $0.score < $1.score }) {
            let (v4, v6) = addressesOfInterface(named: best.name)
            return Snapshot(name: best.name, type: best.type, ipv4: v4, ipv6: v6, foreignVPNActive: foreignVPN)
        }
        #endif
        return Snapshot(name: "", type: .none, ipv4: "", ipv6: "", foreignVPNActive: foreignVPN)
    }

    nonisolated static func addressesOfInterface(named target: String) -> (ipv4: String, ipv6: String) {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let head else { return ("", "") }
        defer { freeifaddrs(head) }

        var ipv4 = ""
        var ipv6 = ""
        var node: UnsafeMutablePointer<ifaddrs>? = head
        while let ptr = node {
            defer { node = ptr.pointee.ifa_next }
            let name = String(cString: ptr.pointee.ifa_name)
            guard name == target, let saPtr = ptr.pointee.ifa_addr else { continue }
            let family = saPtr.pointee.sa_family

            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let saLen: socklen_t
            switch Int32(family) {
            case AF_INET:
                saLen = socklen_t(MemoryLayout<sockaddr_in>.size)
            case AF_INET6:
                saLen = socklen_t(MemoryLayout<sockaddr_in6>.size)
            default:
                continue
            }
            let rc = getnameinfo(saPtr, saLen, &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST)
            guard rc == 0 else { continue }
            let address = String(cString: host)
            switch Int32(family) {
            case AF_INET where ipv4.isEmpty:
                ipv4 = address
            case AF_INET6 where ipv6.isEmpty:
                // Skip link-local fe80::/10 since it's not routable.
                if !address.lowercased().hasPrefix("fe80") {
                    ipv6 = address
                }
            default:
                break
            }
        }
        return (ipv4, ipv6)
        #else
        return ("", "")
        #endif
    }

    nonisolated private static func isVPNName(_ name: String) -> Bool {
        name.hasPrefix("utun") ||
        name.hasPrefix("ipsec") ||
        name.hasPrefix("ppp") ||
        name.hasPrefix("tap") ||
        name.hasPrefix("tun")
    }
}
