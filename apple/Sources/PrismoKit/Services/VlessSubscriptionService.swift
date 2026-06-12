import Foundation

/// Parses `vless://` links and fetches the user's VLESS subscription from the
/// Prismo backend (`GET /sub/{token}`), which returns a base64-encoded list of
/// `vless://` links — the same payload v2rayNG / Happ consume.
///
/// This powers the "Speed" mode (regular VLESS servers, pick a country).
public enum VlessSubscriptionService {
    public enum SubscriptionError: LocalizedError {
        case emptyToken
        case network(String)
        case badResponse
        case noServers

        public var errorDescription: String? {
            switch self {
            case .emptyToken:
                return AppLocalization.string("Token is required.")
            case .network(let message):
                return message
            case .badResponse:
                return AppLocalization.string("Unexpected response from the Prismo server.")
            case .noServers:
                return AppLocalization.string("Subscription did not contain any servers.")
            }
        }
    }

    /// Default base URL of the subscription endpoint.
    public static let defaultBaseURL = URL(string: "https://prismovpn.org")!

    // MARK: - Parsing

    /// Parses a single `vless://uuid@host:port?params#name` link.
    /// Returns nil for non-VLESS or malformed input.
    public static func parse(_ link: String) -> VlessServer? {
        let trimmed = link.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.lowercased().hasPrefix("vless://") else { return nil }

        // Fragment (name) is percent-encoded; split it off first.
        var rest = String(trimmed.dropFirst("vless://".count))
        var name = ""
        if let hashIdx = rest.firstIndex(of: "#") {
            name = String(rest[rest.index(after: hashIdx)...])
                .removingPercentEncoding ?? String(rest[rest.index(after: hashIdx)...])
            rest = String(rest[..<hashIdx])
        }

        // Split query.
        var query = ""
        if let qIdx = rest.firstIndex(of: "?") {
            query = String(rest[rest.index(after: qIdx)...])
            rest = String(rest[..<qIdx])
        }

        // rest is now `uuid@host:port`.
        guard let atIdx = rest.firstIndex(of: "@") else { return nil }
        let uuid = String(rest[..<atIdx])
        let hostPort = String(rest[rest.index(after: atIdx)...])
        guard !uuid.isEmpty else { return nil }

        // host:port — host may be IPv6 in brackets.
        let host: String
        let port: Int
        if hostPort.hasPrefix("[") {
            guard let close = hostPort.firstIndex(of: "]") else { return nil }
            host = String(hostPort[hostPort.index(after: hostPort.startIndex)..<close])
            let after = hostPort[hostPort.index(after: close)...]
            guard after.hasPrefix(":"), let p = Int(after.dropFirst()) else { return nil }
            port = p
        } else {
            guard let colon = hostPort.lastIndex(of: ":"),
                  let p = Int(hostPort[hostPort.index(after: colon)...]) else { return nil }
            host = String(hostPort[..<colon])
            port = p
        }
        guard !host.isEmpty else { return nil }

        let params = parseQuery(query)

        let transport = VlessServer.Transport(rawValue: (params["type"] ?? "tcp").lowercased()) ?? .tcp
        let security = VlessServer.Security(rawValue: (params["security"] ?? "none").lowercased()) ?? .none

        return VlessServer(
            name: name,
            uuid: uuid,
            host: host,
            port: port,
            transport: transport,
            security: security,
            sni: params["sni"],
            fingerprint: params["fp"],
            flow: params["flow"],
            publicKey: params["pbk"],
            shortID: params["sid"],
            serviceName: params["serviceName"],
            path: params["path"]?.removingPercentEncoding ?? params["path"],
            hostHeader: params["host"]
        )
    }

    /// Parses a full subscription body — either raw newline-separated links or
    /// a base64-encoded blob of them. Skips anything that is not VLESS.
    public static func parseSubscription(_ body: String) -> [VlessServer] {
        let decoded = decodeIfBase64(body) ?? body
        return decoded
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .compactMap { parse(String($0)) }
    }

    // MARK: - Fetching

    /// Fetches and parses the VLESS subscription for the given token.
    public static func fetchServers(
        token rawToken: String,
        baseURL: URL = defaultBaseURL,
        session: URLSession = .shared
    ) async throws -> [VlessServer] {
        let token = try PrismoTokenService.extractToken(from: rawToken)
        guard !token.isEmpty else { throw SubscriptionError.emptyToken }

        let url = baseURL.appendingPathComponent("sub").appendingPathComponent(token)
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        // Identify as a known VPN client UA so the backend's anti-scraper
        // filter serves the real config (see app/services/security/sub_filter.py).
        request.setValue("Happ/1 PrismoDNS-iOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw SubscriptionError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw SubscriptionError.badResponse
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw SubscriptionError.badResponse
        }

        let servers = parseSubscription(body)
        guard !servers.isEmpty else { throw SubscriptionError.noServers }
        return servers
    }

    // MARK: - Helpers

    private static func parseQuery(_ query: String) -> [String: String] {
        var out: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard let key = kv.first else { continue }
            let value = kv.count > 1 ? String(kv[1]) : ""
            out[String(key)] = value
        }
        return out
    }

    /// Returns the decoded string if `s` looks like base64 of a VLESS list,
    /// otherwise nil.
    private static func decodeIfBase64(_ s: String) -> String? {
        let compact = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if compact.lowercased().hasPrefix("vless://") { return nil }
        // Tolerate base64url and missing padding.
        var b64 = compact
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
            .replacingOccurrences(of: "\n", with: "")
            .replacingOccurrences(of: "\r", with: "")
        let remainder = b64.count % 4
        if remainder > 0 { b64.append(String(repeating: "=", count: 4 - remainder)) }
        guard let data = Data(base64Encoded: b64),
              let decoded = String(data: data, encoding: .utf8),
              decoded.lowercased().contains("vless://") else {
            return nil
        }
        return decoded
    }
}
