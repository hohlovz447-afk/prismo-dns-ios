import Foundation

/// Fetches a ready-to-use ``ConnectionProfile`` from the Prismo VPN backend
/// using only the user's access token. This is the "one tap" path: the user
/// pastes the token they get from the Telegram bot (or opens a
/// `prismodns://token?...` deep link) and the app pulls the domain + key from
/// `GET /api/dns-tunnel/verify/{token}` instead of asking them to type the
/// delegated domain and encryption key by hand.
public enum PrismoTokenService {
    /// Default API host. Can be overridden per-call (e.g. for staging) but the
    /// production bot serves the DNS-tunnel verify endpoint from here.
    /// Verified: GET https://prismovpn.org/api/dns-tunnel/verify/{token}
    /// returns the JSON tunnel config (other subdomains do not route it).
    public static let defaultBaseURL = URL(string: "https://prismovpn.org")!

    public enum TokenError: LocalizedError {
        case emptyToken
        case invalidLink
        case network(String)
        case invalidToken
        case expired
        case badResponse
        case missingTunnelConfig

        public var errorDescription: String? {
            switch self {
            case .emptyToken:
                return AppLocalization.string("Token is required.")
            case .invalidLink:
                return AppLocalization.string("Invalid Prismo token link.")
            case .network(let message):
                return message
            case .invalidToken:
                return AppLocalization.string("This token is not valid.")
            case .expired:
                return AppLocalization.string("Your subscription is expired or inactive.")
            case .badResponse, .missingTunnelConfig:
                return AppLocalization.string("Unexpected response from the Prismo server.")
            }
        }
    }

    /// Extracts the raw token from any of the forms the user might paste:
    ///   - a bare token: `ReMpAQ7U7hg`
    ///   - a deep link: `prismodns://token?value=...` / `zanoza://token?value=...`
    ///   - a subscription URL: `https://prismovpn.org/sub/ReMpAQ7U7hg` (the
    ///     exact link the Telegram bot hands out) — token is the path segment
    ///     after `/sub/`.
    public static func extractToken(from input: String) throws -> String {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw TokenError.emptyToken }

        if let comps = URLComponents(string: trimmed),
           let scheme = comps.scheme?.lowercased() {
            // Deep link: prismodns://token?value=... / zanoza://token?value=...
            if scheme == "prismodns" || scheme == "zanoza" {
                guard comps.host == "token",
                      let value = comps.queryItems?.first(where: { $0.name == "value" || $0.name == "token" })?.value,
                      !value.isEmpty else {
                    throw TokenError.invalidLink
                }
                return value
            }

            // Subscription URL: https://<host>/sub/<token>[?...]. Take the path
            // segment right after the "sub" component.
            if scheme == "http" || scheme == "https" {
                let segments = comps.path
                    .split(separator: "/", omittingEmptySubsequences: true)
                    .map(String.init)
                if let subIdx = segments.firstIndex(of: "sub"),
                   subIdx + 1 < segments.count {
                    let token = segments[subIdx + 1]
                    if !token.isEmpty {
                        return token
                    }
                }
                // Fallback: a plain link to /sub with no trailing token, or some
                // other http(s) URL we don't recognise.
                if let last = segments.last, !last.isEmpty, last != "sub" {
                    return last
                }
                throw TokenError.invalidLink
            }

            // Any other scheme (ftp://, etc.) is not a valid Prismo token.
            throw TokenError.invalidLink
        }

        // A bare token must not look like some other URL scheme.
        if trimmed.contains("://") {
            throw TokenError.invalidLink
        }
        return trimmed
    }

    /// Full result of a verify call: the ready-to-use profile, the validated
    /// token (so the app can re-check the subscription later) and the expiry.
    public struct VerifiedSubscription {
        public let profile: ConnectionProfile
        public let token: String
        public let expiresAt: Date?
    }

    /// Calls the Prismo backend and returns a fully populated profile.
    /// Convenience wrapper around ``verify(token:)``.
    public static func fetchProfile(
        token rawToken: String,
        baseURL: URL = defaultBaseURL,
        session: URLSession = .shared
    ) async throws -> ConnectionProfile {
        try await verify(token: rawToken, baseURL: baseURL, session: session).profile
    }

    /// Calls the Prismo backend, validates the subscription and returns the
    /// profile together with the token and expiry date. Throws ``TokenError``
    /// for invalid (404) / expired (403) / network problems so the caller can
    /// surface a precise message.
    public static func verify(
        token rawToken: String,
        baseURL: URL = defaultBaseURL,
        session: URLSession = .shared
    ) async throws -> VerifiedSubscription {
        let token = try extractToken(from: rawToken)

        let url = baseURL
            .appendingPathComponent("api")
            .appendingPathComponent("dns-tunnel")
            .appendingPathComponent("verify")
            .appendingPathComponent(token)

        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("PrismoDNS-iOS", forHTTPHeaderField: "User-Agent")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw TokenError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw TokenError.badResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 404:
            throw TokenError.invalidToken
        case 403:
            throw TokenError.expired
        default:
            throw TokenError.badResponse
        }

        let decoded: VerifyResponse
        do {
            decoded = try JSONDecoder().decode(VerifyResponse.self, from: data)
        } catch {
            throw TokenError.badResponse
        }

        guard let config = decoded.tunnelConfig else {
            throw TokenError.missingTunnelConfig
        }

        // `domains` may carry several comma/newline-separated entries; the
        // tunnel only needs one delegated domain.
        let domain = config.primaryDomain
        guard !domain.isEmpty, !config.encryptionKey.isEmpty else {
            throw TokenError.missingTunnelConfig
        }

        let profile = ConnectionProfile(
            name: ConnectionProfile.bypassProfileName,
            domain: domain,
            encryptionKey: config.encryptionKey,
            encryptionMethod: EncryptionMethod(rawValue: config.encryptionMethod) ?? .xor
        )

        return VerifiedSubscription(
            profile: profile,
            token: token,
            expiresAt: decoded.expiryDate
        )
    }

    // MARK: - Wire format

    private struct VerifyResponse: Decodable {
        let status: String?
        let tunnelConfig: TunnelConfig?
        let expiresAt: String?
        let expiresTs: Int?

        enum CodingKeys: String, CodingKey {
            case status
            case tunnelConfig = "tunnel_config"
            case expiresAt = "expires_at"
            case expiresTs = "expires_ts"
        }

        /// Subscription expiry from either the unix timestamp or ISO-8601 field.
        var expiryDate: Date? {
            if let ts = expiresTs {
                return Date(timeIntervalSince1970: TimeInterval(ts))
            }
            if let iso = expiresAt {
                let formatter = ISO8601DateFormatter()
                formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
                if let date = formatter.date(from: iso) { return date }
                formatter.formatOptions = [.withInternetDateTime]
                return formatter.date(from: iso)
            }
            return nil
        }
    }

    private struct TunnelConfig: Decodable {
        let domains: String
        let encryptionKey: String
        let encryptionMethod: Int

        enum CodingKeys: String, CodingKey {
            case domains
            case encryptionKey = "encryption_key"
            case encryptionMethod = "data_encryption_method"
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            domains = try c.decodeIfPresent(String.self, forKey: .domains) ?? ""
            encryptionKey = try c.decodeIfPresent(String.self, forKey: .encryptionKey) ?? ""
            // The server config uses DATA_ENCRYPTION_METHOD = 1 (XOR) today;
            // fall back to that if the field is absent.
            encryptionMethod = try c.decodeIfPresent(Int.self, forKey: .encryptionMethod) ?? 1
        }

        var primaryDomain: String {
            domains
                .split(whereSeparator: { $0 == "," || $0 == "\n" || $0 == " " })
                .first
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                ?? ""
        }
    }
}
