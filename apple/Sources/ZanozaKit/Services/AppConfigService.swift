import Foundation

/// Fetches and caches the server-driven `AppConfigCatalog` from the Prismo
/// backend (`GET /api/app-config`). Resolves to, in order of preference:
///   1. fresh server catalog (and caches it on disk),
///   2. last cached catalog,
///   3. the bundled fallback.
///
/// This is what lets the app keep ZERO hardcoded resolver data.
public final class AppConfigService {
    public static let shared = AppConfigService()

    public static let defaultBaseURL = URL(string: "https://prismovpn.org")!

    private let fileURL: URL
    private let queue = DispatchQueue(label: "org.prismovpn.appconfig")
    private var memoryCache: AppConfigCatalog?

    private init() {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("app-config.json")
    }

    /// The best catalog available right now without hitting the network:
    /// memory cache → disk cache → bundled fallback.
    public func current() -> AppConfigCatalog {
        if let memoryCache { return memoryCache }
        if let disk = loadFromDisk() {
            memoryCache = disk
            return disk
        }
        return .bundledFallback
    }

    /// Fetches a fresh catalog from the backend and updates the caches.
    /// On any failure returns the best locally available catalog instead of
    /// throwing, so callers can always proceed.
    @discardableResult
    public func refresh(
        baseURL: URL = defaultBaseURL,
        session: URLSession = .shared
    ) async -> AppConfigCatalog {
        let url = baseURL.appendingPathComponent("api").appendingPathComponent("app-config")
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("PrismoDNS-iOS", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse,
                  (200..<300).contains(http.statusCode) else {
                return current()
            }
            let catalog = try JSONDecoder().decode(AppConfigCatalog.self, from: data)
            store(catalog)
            return catalog
        } catch {
            return current()
        }
    }

    // MARK: - Persistence

    private func store(_ catalog: AppConfigCatalog) {
        memoryCache = catalog
        queue.async {
            guard let data = try? JSONEncoder().encode(catalog) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }

    private func loadFromDisk() -> AppConfigCatalog? {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(AppConfigCatalog.self, from: data) else {
                return nil
            }
            return decoded
        }
    }
}
