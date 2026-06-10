import Foundation

/// Result of the most recent subscription check against the Prismo backend.
public enum SubscriptionStatus: String, Codable, Equatable {
    /// Subscription is valid and the tunnel may be used.
    case active
    /// Token is valid but the subscription has expired / been disabled.
    case expired
    /// Token does not exist on the backend.
    case invalid
    /// We could not reach the backend; the last known status still applies.
    case unknown
}

/// Persisted subscription state so the app can silently re-validate the
/// subscription on launch / before connecting, without forcing the user to
/// paste their token again.
///
/// NOTE: the access token is a bearer secret. It is stored in the app's
/// Documents container today; migrating it to the Keychain is tracked
/// separately (see docs/APPLE-DEVELOPER-SETUP.md → Keychain Sharing).
public struct SubscriptionState: Codable, Equatable {
    public var token: String
    public var status: SubscriptionStatus
    public var expiresAt: Date?
    public var lastCheckedAt: Date?

    public init(
        token: String,
        status: SubscriptionStatus = .unknown,
        expiresAt: Date? = nil,
        lastCheckedAt: Date? = nil
    ) {
        self.token = token
        self.status = status
        self.expiresAt = expiresAt
        self.lastCheckedAt = lastCheckedAt
    }

    /// True when the backend last reported the subscription as usable.
    public var isUsable: Bool {
        switch status {
        case .active:
            return true
        case .unknown:
            // Grace period: if we previously knew an expiry and it is still in
            // the future, allow connecting offline.
            if let expiresAt { return expiresAt > Date() }
            return false
        case .expired, .invalid:
            return false
        }
    }
}

public final class SubscriptionStore {
    public static let shared = SubscriptionStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "org.prismovpn.subscriptionstore")

    private init() {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("subscription.json")
    }

    public func load() -> SubscriptionState? {
        queue.sync {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? decoder.decode(SubscriptionState.self, from: data) else {
                return nil
            }
            return decoded
        }
    }

    public func save(_ state: SubscriptionState) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            guard let data = try? encoder.encode(state) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    public func clear() {
        queue.async {
            try? FileManager.default.removeItem(at: self.fileURL)
        }
    }
}
