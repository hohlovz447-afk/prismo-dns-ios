import Foundation

/// Crowd-sourced resolver health reporting.
///
/// Server-side validation of resolvers is useless under censorship: a resolver
/// that answers from a datacenter can be throttled/blocked on a given mobile
/// operator. So every device measures REAL per-resolver tunnel health on its
/// own network (the engine's passive stats) and POSTs an anonymized summary
/// here. The backend aggregates by operator/region and feeds the ranking back
/// through `/api/app-config`, so the whole fleet keeps the resolver lists fresh
/// with no manual validation.
///
/// Reports are fully ANONYMOUS — no token, no user id, only the operator PLMN
/// plus per-resolver loss/RTT counters.
public enum ResolverReportService {
    /// One reported resolver measurement (mirrors the engine's stats JSON).
    private struct Sample: Encodable {
        let resolver: String
        let sent: UInt64
        let acked: UInt64
        let lost: UInt64
        let rtt_ms: UInt64
    }

    private struct Report: Encodable {
        let plmn: String?
        let samples: [Sample]
    }

    /// Decodes the engine stats JSON, keeps entries with enough samples to be
    /// meaningful, and POSTs them to the backend. Best-effort: any failure is
    /// swallowed (this must never affect the tunnel).
    public static func report(
        statsJSON: String,
        baseURL: URL = AppConfigService.defaultBaseURL,
        session: URLSession = .shared
    ) async {
        guard let data = statsJSON.data(using: .utf8),
              let stats = try? JSONDecoder().decode([EngineResolverStat].self, from: data),
              !stats.isEmpty else {
            return
        }

        // Only report resolvers actually exercised this session (>= 20 packets),
        // so the aggregate isn't polluted by resolvers that never carried traffic.
        let samples = stats.compactMap { s -> Sample? in
            guard s.sent >= 20 else { return nil }
            return Sample(resolver: s.resolver, sent: s.sent, acked: s.acked,
                          lost: s.lost, rtt_ms: s.rtt_ms)
        }
        guard !samples.isEmpty else { return }

        let plmn = CarrierDetector.currentPLMN()
        let report = Report(plmn: (plmn?.isEmpty == false) ? plmn : nil, samples: samples)
        guard let body = try? JSONEncoder().encode(report) else { return }

        let url = baseURL.appendingPathComponent("api").appendingPathComponent("resolver-report")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("PrismoDNS-iOS", forHTTPHeaderField: "User-Agent")
        request.httpBody = body

        _ = try? await session.data(for: request)
    }
}

/// One entry of the engine's passive per-resolver health JSON
/// (`GetResolverStats`): [{"resolver","valid","sent","acked","lost","rtt_ms"}].
struct EngineResolverStat: Decodable {
    let resolver: String
    let valid: Bool
    let sent: UInt64
    let acked: UInt64
    let lost: UInt64
    let rtt_ms: UInt64
}
