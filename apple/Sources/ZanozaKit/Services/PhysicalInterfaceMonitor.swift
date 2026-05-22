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

// Watches the active physical network path and pushes the BSD interface
// name of the underlying Wi-Fi / cellular / Ethernet link into the Go
// client via MobileSetBoundInterface. NetworkExtension VPN interfaces
// (utun*, ipsec*, tap*) are excluded so we never try to bind our outbound
// DNS sockets to another app's tunnel.
@MainActor
public final class PhysicalInterfaceMonitor: ObservableObject {
    public struct Snapshot: Equatable {
        public let name: String          // BSD name, e.g. "en0"
        public let type: InterfaceType
        public static let none = Snapshot(name: "", type: .none)
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

    #if canImport(Network)
    private let pathMonitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "io.zanoza.physical-interface")
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

        // Apply an initial best-effort snapshot before the path-update
        // callback fires (it can take a few hundred ms on cold launch).
        apply(PhysicalInterfaceMonitor.resolveFromGetifaddrs(preferring: nil))
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
        snapshot = next
        push(name: next.name)
    }

    private func push(name: String) {
        #if canImport(Mobile)
        MobileSetBoundInterface(name)
        #else
        _ = name
        #endif
    }

    // MARK: - Resolution helpers

    #if canImport(Network)
    nonisolated static func resolveInterface(path: NWPath) -> Snapshot {
        guard path.status == .satisfied else {
            return resolveFromGetifaddrs(preferring: nil)
        }
        var preferredType: InterfaceType?
        if path.usesInterfaceType(.wiredEthernet) { preferredType = .wired }
        else if path.usesInterfaceType(.wifi) { preferredType = .wifi }
        else if path.usesInterfaceType(.cellular) { preferredType = .cellular }

        // NWInterface.name is the BSD name on iOS / macOS (Apple has
        // confirmed this in WWDC sessions, though it's not in the headers
        // contract). Fall back to getifaddrs if it ever isn't.
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
                return Snapshot(name: name, type: preferredType)
            }
        }
        return resolveFromGetifaddrs(preferring: preferredType)
    }
    #endif

    // Walks the BSD interface table directly. Filters to UP+RUNNING,
    // non-loopback, non-VPN, prefers en* then pdp_ip* then anything else.
    nonisolated static func resolveFromGetifaddrs(preferring preferred: InterfaceType?) -> Snapshot {
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
            seen.append((name, type, score))
        }

        if let preferred {
            if let hit = seen.first(where: { $0.type == preferred }) {
                return Snapshot(name: hit.name, type: hit.type)
            }
        }
        if let best = seen.max(by: { $0.score < $1.score }) {
            return Snapshot(name: best.name, type: best.type)
        }
        #endif
        return .none
    }

    nonisolated private static func isVPNName(_ name: String) -> Bool {
        name.hasPrefix("utun") ||
        name.hasPrefix("ipsec") ||
        name.hasPrefix("ppp") ||
        name.hasPrefix("tap") ||
        name.hasPrefix("tun")
    }
}
