import Foundation

#if canImport(Mobile)
import Mobile
#endif

/// On-device resolver speed calibration.
///
/// For each candidate resolver it starts the engine with ONLY that resolver,
/// waits for the tunnel session, then measures real download throughput through
/// the local SOCKS5 proxy (the measurement runs in Go for reliable TLS/HTTP).
/// This is the on-device equivalent of the desktop speed checker, but it runs
/// on the user's actual network, so the ranking reflects what the user really
/// gets under their carrier/region restrictions.
///
/// MUST be called only while the main tunnel is stopped — the engine is a
/// single shared instance.
public enum ResolverCalibrator {
    public struct Sample: Sendable, Equatable {
        public let resolver: String
        public let bytesPerSec: Int64
        public var kbitsPerSec: Double { Double(bytesPerSec) * 8.0 / 1000.0 }
    }

    /// Calibration listener port — distinct from the user's configured SOCKS
    /// port so a stale instance can't collide with the real tunnel.
    public static let calibrationPort = 41099

    /// HTTPS file pulled through the tunnel to measure throughput. Cloudflare's
    /// speed endpoint is globally reachable and lets us cap the size.
    private static let downloadURL = "https://speed.cloudflare.com/__down?bytes=10000000"

    /// Probes each `candidate` sequentially and returns samples sorted
    /// fastest-first. Resolvers that fail to start / never form a session /
    /// time out get a 0 sample (kept so the caller can show them as failed).
    public static func calibrate(
        configTOML: String,
        candidates: [String],
        runtimeDirectory: URL,
        boundInterface: String,
        boundIPv4: String,
        boundIPv6: String,
        sessionTimeout: TimeInterval = 7.0,
        downloadTimeout: TimeInterval = 6.0,
        downloadBytes: Int = 3_000_000,
        progress: @Sendable @escaping (_ done: Int, _ total: Int, _ resolver: String) -> Void
    ) async -> [Sample] {
        let unique = orderedUnique(candidates)
        guard !unique.isEmpty else { return [] }

        return await withCheckedContinuation { (continuation: CheckedContinuation<[Sample], Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                var samples: [Sample] = []
                let total = unique.count
                for (index, resolver) in unique.enumerated() {
                    let bps = measureOne(
                        configTOML: configTOML,
                        resolver: resolver,
                        runtimeDirectory: runtimeDirectory,
                        boundInterface: boundInterface,
                        boundIPv4: boundIPv4,
                        boundIPv6: boundIPv6,
                        sessionTimeout: sessionTimeout,
                        downloadTimeout: downloadTimeout,
                        downloadBytes: downloadBytes
                    )
                    samples.append(Sample(resolver: resolver, bytesPerSec: bps))
                    progress(index + 1, total, resolver)
                }
                continuation.resume(returning: samples.sorted { $0.bytesPerSec > $1.bytesPerSec })
            }
        }
    }

    private static func measureOne(
        configTOML: String,
        resolver: String,
        runtimeDirectory: URL,
        boundInterface: String,
        boundIPv4: String,
        boundIPv6: String,
        sessionTimeout: TimeInterval,
        downloadTimeout: TimeInterval,
        downloadBytes: Int
    ) -> Int64 {
        #if canImport(Mobile)
        MobileSetBoundInterface(boundInterface)
        MobileSetBoundAddress(boundIPv4, boundIPv6)

        var startError: NSError?
        let started = MobileStart(configTOML, resolver, runtimeDirectory.path, &startError)
        if !started {
            MobileStop()
            return 0
        }

        // Wait for the tunnel session to come up for this single resolver.
        var ready = false
        let polls = max(1, Int(sessionTimeout / 0.25))
        for _ in 0..<polls {
            if MobileSessionReady() { ready = true; break }
            Thread.sleep(forTimeInterval: 0.25)
        }

        var bytesPerSec: Int64 = 0
        if ready {
            bytesPerSec = MobileMeasureDownloadBytesPerSec(
                "127.0.0.1:\(calibrationPort)",
                downloadURL,
                downloadBytes,
                downloadTimeout
            )
        }

        MobileStop()
        // Give the listener a moment to release the port before the next start.
        Thread.sleep(forTimeInterval: 0.3)
        return bytesPerSec
        #else
        _ = (configTOML, resolver, runtimeDirectory, boundInterface, boundIPv4, boundIPv6,
             sessionTimeout, downloadTimeout, downloadBytes)
        return 0
        #endif
    }

    private static func orderedUnique(_ items: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for raw in items {
            let ip = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if ip.isEmpty || seen.contains(ip) { continue }
            seen.insert(ip)
            out.append(ip)
        }
        return out
    }
}
