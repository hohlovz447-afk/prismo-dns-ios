import Foundation
import Network

/// Lightweight reachability probe for DNS resolvers.
///
/// For each candidate resolver IP we send a small UDP DNS query (A record for
/// a stable domain) and measure how long it takes to get a valid response.
/// Resolvers that answer are "alive"; the list is sorted fastest-first so the
/// tunnel uses resolvers that actually work on the user's current network
/// (different RU carriers / regions block different resolvers).
///
/// This is the "light" scan: a single UDP round-trip per resolver, run in
/// parallel with a short timeout, so it's cheap on battery and data.
public enum ResolverProbe {
    public struct Result: Sendable {
        public let resolver: String
        public let latencyMs: Int
    }

    /// Domain we resolve as the probe. `.` style root/NS query would be ideal
    /// but a plain A query for a ubiquitous name is simplest and works on any
    /// open resolver.
    private static let probeDomain = "www.google.com"
    private static let dnsPort: UInt16 = 53

    /// Probes `resolvers` concurrently and returns the ones that answered,
    /// sorted fastest-first. Never throws — unreachable resolvers are simply
    /// omitted. `timeout` is per-resolver.
    public static func probeAll(
        _ resolvers: [String],
        timeout: TimeInterval = 2.0
    ) async -> [Result] {
        let unique = Array(Set(resolvers)).filter { !$0.isEmpty }
        guard !unique.isEmpty else { return [] }

        let results = await withTaskGroup(of: Result?.self) { group -> [Result] in
            for ip in unique {
                group.addTask {
                    await probeOne(ip, timeout: timeout)
                }
            }
            var collected: [Result] = []
            for await r in group {
                if let r { collected.append(r) }
            }
            return collected
        }
        return results.sorted { $0.latencyMs < $1.latencyMs }
    }

    /// Probes a single resolver. Returns nil if it didn't answer in time.
    public static func probeOne(_ ip: String, timeout: TimeInterval) async -> Result? {
        guard let port = NWEndpoint.Port(rawValue: dnsPort) else { return nil }
        let host = NWEndpoint.Host(ip)
        let query = makeDNSQuery(domain: probeDomain)

        let connection = NWConnection(host: host, port: port, using: .udp)
        let queue = DispatchQueue(label: "org.prismovpn.resolver-probe")
        let start = DispatchTime.now()

        return await withCheckedContinuation { (continuation: CheckedContinuation<Result?, Never>) in
            let state = ProbeState()

            func finish(_ value: Result?) {
                guard state.tryFinish() else { return }
                connection.cancel()
                continuation.resume(returning: value)
            }

            connection.stateUpdateHandler = { newState in
                switch newState {
                case .ready:
                    connection.send(content: query, completion: .contentProcessed { error in
                        if error != nil { finish(nil); return }
                        connection.receiveMessage { data, _, _, error in
                            if let data, error == nil, isValidDNSResponse(data) {
                                let ms = Int(Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
                                finish(Result(resolver: ip, latencyMs: max(ms, 1)))
                            } else {
                                finish(nil)
                            }
                        }
                    })
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) { finish(nil) }
            connection.start(queue: queue)
        }
    }

    // MARK: - DNS wire format

    /// Builds a minimal DNS query packet (A record, recursion desired).
    static func makeDNSQuery(domain: String) -> Data {
        var packet = Data()
        // Header: random ID, flags = 0x0100 (standard query, RD), 1 question.
        let id = UInt16.random(in: 0...UInt16.max)
        packet.append(UInt8(id >> 8)); packet.append(UInt8(id & 0xff))
        packet.append(contentsOf: [0x01, 0x00])  // flags: RD
        packet.append(contentsOf: [0x00, 0x01])  // QDCOUNT = 1
        packet.append(contentsOf: [0x00, 0x00])  // ANCOUNT
        packet.append(contentsOf: [0x00, 0x00])  // NSCOUNT
        packet.append(contentsOf: [0x00, 0x00])  // ARCOUNT

        // Question: QNAME (length-prefixed labels), QTYPE=A, QCLASS=IN.
        for label in domain.split(separator: ".") {
            let bytes = Array(label.utf8)
            packet.append(UInt8(bytes.count))
            packet.append(contentsOf: bytes)
        }
        packet.append(0x00)                        // end of QNAME
        packet.append(contentsOf: [0x00, 0x01])    // QTYPE = A
        packet.append(contentsOf: [0x00, 0x01])    // QCLASS = IN
        return packet
    }

    /// A response is "valid enough" if it echoes a DNS header with the QR bit
    /// set and at least one answer (or a NOERROR/NXDOMAIN with the response
    /// flag) — meaning the resolver is reachable and answering, not silently
    /// dropped by the network.
    static func isValidDNSResponse(_ data: Data) -> Bool {
        guard data.count >= 12 else { return false }
        let flagsHi = data[data.startIndex + 2]
        // QR bit (response) must be set.
        return (flagsHi & 0x80) != 0
    }
}

private final class ProbeState: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false

    func tryFinish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if finished { return false }
        finished = true
        return true
    }
}
