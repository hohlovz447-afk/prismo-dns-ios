import Foundation

/// Persistent, per-network store of working resolvers.
///
/// The app probes the (wide) candidate pool on the user's current network,
/// keeps the resolvers that actually answer, and persists them keyed by the
/// network (mobile operator PLMN, or Wi-Fi). On the next connect from the same
/// network the working set is reused instantly; when the network changes or the
/// set goes stale it is re-probed. This is the "app builds and maintains its
/// own working resolver list" layer.
public final class ResolverHealthStore {
    public static let shared = ResolverHealthStore()

    public struct Entry: Codable, Equatable {
        public var resolvers: [String]
        public var updatedAt: Date
    }

    /// Working sets older than this are considered stale and re-probed.
    public static let defaultMaxAge: TimeInterval = 24 * 60 * 60

    private let queue = DispatchQueue(label: "org.prismovpn.resolverhealth")
    private let fileURL: URL
    private var cache: [String: Entry]

    private init() {
        let fm = FileManager.default
        let dir = (try? fm.url(for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true))
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("resolver-health-v2.json")
        if let data = try? Data(contentsOf: fileURL),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) {
            cache = decoded
        } else {
            cache = [:]
        }
    }

    /// Key identifying the current network: the mobile operator (PLMN) when on
    /// cellular, otherwise a generic Wi-Fi bucket.
    public func currentNetworkKey() -> String {
        if let plmn = CarrierDetector.currentPLMN(), !plmn.isEmpty {
            return "plmn:\(plmn)"
        }
        return "wifi"
    }

    /// Returns the stored working resolvers for `key` if present and fresher
    /// than `maxAge`, else nil.
    public func working(for key: String, maxAge: TimeInterval = defaultMaxAge) -> [String]? {
        queue.sync {
            guard let entry = cache[key],
                  Date().timeIntervalSince(entry.updatedAt) <= maxAge,
                  !entry.resolvers.isEmpty else {
                return nil
            }
            return entry.resolvers
        }
    }

    /// Stores the working resolvers for `key` and persists to disk.
    public func store(_ resolvers: [String], for key: String) {
        guard !resolvers.isEmpty else { return }
        queue.async {
            self.cache[key] = Entry(resolvers: resolvers, updatedAt: Date())
            self.persistLocked()
        }
    }

    /// Drops `resolvers` from the stored set for `key` (e.g. after the engine
    /// reported them as failing during a session). Keeps the rest.
    public func prune(_ bad: [String], for key: String) {
        guard !bad.isEmpty else { return }
        let badSet = Set(bad)
        queue.async {
            guard var entry = self.cache[key] else { return }
            entry.resolvers.removeAll { badSet.contains($0) }
            entry.updatedAt = Date()
            self.cache[key] = entry
            self.persistLocked()
        }
    }

    /// Forgets the stored set for `key`, forcing a fresh probe next time.
    public func invalidate(_ key: String) {
        queue.async {
            self.cache.removeValue(forKey: key)
            self.persistLocked()
        }
    }

    private func persistLocked() {
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}


/// One entry of the engine's passive per-resolver health JSON.
private struct ResolverStatJSON: Decodable {
    let resolver: String
    let valid: Bool
    let sent: UInt64
    let acked: UInt64
    let lost: UInt64
    let rtt_ms: UInt64
}

public enum ResolverHealth {
    /// Parses the engine's `GetResolverStats` JSON and returns resolvers that
    /// clearly underperformed during the session — engine-invalidated or high
    /// packet loss, with enough samples to be confident. Conservative on
    /// purpose so good resolvers are never dropped.
    public static func badResolvers(fromJSON json: String) -> [String] {
        guard let data = json.data(using: .utf8),
              let stats = try? JSONDecoder().decode([ResolverStatJSON].self, from: data) else {
            return []
        }
        return stats.compactMap { s in
            guard s.sent >= 20 else { return nil }
            let highLoss = s.lost * 2 > s.sent
            return (!s.valid || highLoss) ? s.resolver : nil
        }
    }
}
