import Foundation
import Network
import Security

public enum ResolverListError: LocalizedError {
    case downloadFailed(URL, String)
    case invalidHTTPStatus(URL, Int)
    case invalidHTTPResponse(URL)
    case invalidEncoding(URL)
    case invalidResolverEntry(String, Int, String)
    case emptyResolverList(String)

    public var errorDescription: String? {
        switch self {
        case .downloadFailed(let url, let message):
            return AppLocalization.format("Failed to download DNS resolver list (%@): %@", url.absoluteString, message)
        case .invalidHTTPStatus(let url, let status):
            return AppLocalization.format("DNS resolver list request failed (%@): HTTP %d", url.absoluteString, status)
        case .invalidHTTPResponse(let url):
            return AppLocalization.format("Invalid DNS resolver list response: %@", url.absoluteString)
        case .invalidEncoding(let url):
            return AppLocalization.format("DNS resolver list is not UTF-8: %@", url.absoluteString)
        case .invalidResolverEntry(let source, let line, let value):
            return AppLocalization.format("Invalid DNS resolver entry in %@ on line %d: %@", source, line, value)
        case .emptyResolverList(let source):
            return AppLocalization.format("DNS resolver list is empty: %@", source)
        }
    }
}

public enum ResolverListService {
    public typealias TextFetcher = (URL) throws -> String

    /// Live resolvers discovered by the most recent ``ResolverProbe`` scan,
    /// fastest-first. When present they are placed at the TOP of the resolver
    /// list so the tunnel tries known-working resolvers for the user's current
    /// network before falling back to the rest of the catalog.
    private static let probedLock = NSLock()
    private static var probedLiveResolvers: [String] = []

    /// Stores the result of a resolver probe (see ``scanResolvers``).
    public static func setProbedLiveResolvers(_ resolvers: [String]) {
        probedLock.lock(); defer { probedLock.unlock() }
        probedLiveResolvers = resolvers
    }

    public static func currentProbedLiveResolvers() -> [String] {
        probedLock.lock(); defer { probedLock.unlock() }
        return probedLiveResolvers
    }

    /// Curated, tunnel-capable resolver set fed to the engine.
    ///
    /// Deliberately does NOT include the large raw `all`/`pool` list: most of
    /// those answer plain DNS but do not reliably TUNNEL on a given mobile
    /// network, so feeding them makes the balancer waste packets on dead paths
    /// (high latency/jitter, low throughput). We use the RU carrier + Yandex
    /// resolvers, which forward correctly. The raw pool is only a calibration
    /// candidate source.
    public static func candidates(settings: AppSettings) -> [String] {
        let catalog = AppConfigService.shared.current()
        if settings.useFastResolvers {
            let base = catalog.fast.isEmpty ? catalog.yandex : catalog.fast
            return Array(uniqueOrdered(base).prefix(40))
        }

        var ordered: [String] = []
        // The active operator's own resolvers first (most relevant here),
        if let pinned = catalog.carrier(id: settings.resolverProviderID) {
            ordered += pinned.resolvers
        } else if let plmn = CarrierDetector.currentPLMN(),
                  let carrier = catalog.carrier(forPLMN: plmn) {
            ordered += carrier.resolvers
        }
        // then the universal non-shaping tier (good speed on any network),
        ordered += catalog.noshape
        // then Yandex, then every other operator's resolvers as fill.
        ordered += catalog.yandex
        for carrier in catalog.carriers { ordered += carrier.resolvers }

        let curated = uniqueOrdered(ordered)
        let fallback = uniqueOrdered(catalog.noshape + catalog.yandex)
        let base = curated.isEmpty ? fallback : curated
        return Array(base.prefix(40))
    }

    private static func uniqueOrdered(_ items: [String]) -> [String] {
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

    /// Probes the candidate resolvers for the current network and caches the
    /// live ones (fastest-first) for subsequent ``resolve`` calls. Returns the
    /// number of live resolvers found. Safe to call before connecting.
    @discardableResult
    public static func scanResolvers(settings: AppSettings) async -> Int {
        guard settings.customResolvers
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return 0  // user pinned manual resolvers; nothing to probe
        }
        let pool = candidates(settings: settings)
        guard !pool.isEmpty else { return 0 }
        let live = await ResolverProbe.probeAll(pool)
        // Keep the reachable curated resolvers (fastest-first) for the engine.
        let ranked = Array(live.map(\.resolver).prefix(40))
        guard !ranked.isEmpty else { return 0 }
        setProbedLiveResolvers(ranked)
        // Persist this working set for the current network so a reconnect
        // reuses it instantly and it survives app restarts.
        ResolverHealthStore.shared.store(ranked, for: ResolverHealthStore.shared.currentNetworkKey())
        return ranked.count
    }

    public static func resolve(settings: AppSettings, fetch: TextFetcher? = nil) throws -> String {
        let manual = settings.customResolvers.trimmingCharacters(in: .whitespacesAndNewlines)
        if !manual.isEmpty {
            return manual
        }

        // Self-maintaining per-network working set: if we have a fresh probed
        // set for the current network, use it directly (it's already filtered
        // to resolvers that answered here, fastest-first).
        let networkKey = ResolverHealthStore.shared.currentNetworkKey()
        if let working = ResolverHealthStore.shared.working(for: networkKey), working.count >= 3 {
            return working.joined(separator: "\n") + "\n"
        }

        // Otherwise fall back to the catalog candidate pool, live-probed
        // resolvers first. A background scan keeps the store up to date.
        var list = candidates(settings: settings)
        let live = currentProbedLiveResolvers()
        if !live.isEmpty {
            let remainder = list.filter { !live.contains($0) }
            list = live + remainder
        }

        let text = list.joined(separator: "\n")
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return DefaultResolvers.text
        }
        return text + "\n"
    }

    static func parseResolverLines(_ text: String, sourceName: String) throws -> [String] {
        var resolvers: [String] = []
        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine
                .components(separatedBy: "#")
                .first?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if line.isEmpty {
                continue
            }
            guard isValidIPv4(line) else {
                throw ResolverListError.invalidResolverEntry(sourceName, offset + 1, rawLine)
            }
            resolvers.append(line)
        }
        guard !resolvers.isEmpty else {
            throw ResolverListError.emptyResolverList(sourceName)
        }
        return resolvers
    }

    private static func isValidIPv4(_ text: String) -> Bool {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            guard !part.isEmpty, part.allSatisfy(\.isNumber) else { return false }
            return UInt8(String(part)) != nil
        }
    }
}

private enum NetworkResolverTextFetcher {
    private static let timeout: TimeInterval = 12

    static func fetchText(_ url: URL) throws -> String {
        let data = try fetchData(url)
        guard let text = String(data: data, encoding: .utf8) else {
            throw ResolverListError.invalidEncoding(url)
        }
        return text
    }

    private static func fetchData(_ url: URL) throws -> Data {
        guard url.scheme?.lowercased() == "https",
              let host = url.host,
              let port = NWEndpoint.Port(rawValue: UInt16(url.port ?? 443)) else {
            throw ResolverListError.invalidHTTPResponse(url)
        }

        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        let parameters = NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
        parameters.prohibitedInterfaceTypes = [.other]
        parameters.prohibitExpensivePaths = false
        parameters.prohibitConstrainedPaths = false

        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: parameters)
        let queue = DispatchQueue(label: "org.prismovpn.resolver-fetch")
        let state = ResolverFetchState()
        var response = Data()

        func receive() {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, isComplete, error in
                if let data, !data.isEmpty {
                    response.append(data)
                }
                if let error {
                    state.finish(.failure(ResolverListError.downloadFailed(url, error.localizedDescription)), connection: connection)
                    return
                }
                do {
                    if let body = try responseBodyIfComplete(response, final: isComplete, url: url) {
                        state.finish(.success(body), connection: connection)
                        return
                    }
                } catch {
                    state.finish(.failure(error), connection: connection)
                    return
                }
                if isComplete {
                    state.finish(.failure(ResolverListError.invalidHTTPResponse(url)), connection: connection)
                    return
                }
                receive()
            }
        }

        connection.stateUpdateHandler = { newState in
            switch newState {
            case .ready:
                let request = makeHTTPRequest(for: url, host: host)
                connection.send(content: Data(request.utf8), completion: .contentProcessed { error in
                    if let error {
                        state.finish(.failure(ResolverListError.downloadFailed(url, error.localizedDescription)), connection: connection)
                        return
                    }
                    receive()
                })
            case .failed(let error):
                state.finish(.failure(ResolverListError.downloadFailed(url, error.localizedDescription)), connection: connection)
            case .cancelled:
                break
            default:
                break
            }
        }

        queue.asyncAfter(deadline: .now() + timeout) {
            state.finish(.failure(ResolverListError.downloadFailed(url, AppLocalization.string("Timeout."))), connection: connection)
        }
        connection.start(queue: queue)

        switch state.wait() {
        case .success(let data):
            return data
        case .failure(let error):
            throw error
        }
    }

    private static func makeHTTPRequest(for url: URL, host: String) -> String {
        var target = url.path.isEmpty ? "/" : url.path
        if let query = url.query, !query.isEmpty {
            target += "?\(query)"
        }
        return "GET \(target) HTTP/1.1\r\n"
            + "Host: \(host)\r\n"
            + "User-Agent: Mozilla/5.0\r\n"
            + "Accept: text/plain, */*;q=0.1\r\n"
            + "Connection: close\r\n"
            + "\r\n"
    }

    private static func responseBodyIfComplete(_ response: Data, final: Bool, url: URL) throws -> Data? {
        let separator = Data([13, 10, 13, 10])
        guard let headerRange = response.range(of: separator) else {
            if final {
                throw ResolverListError.invalidHTTPResponse(url)
            }
            return nil
        }

        let headerData = response[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .isoLatin1) else {
            throw ResolverListError.invalidHTTPResponse(url)
        }

        let headerLines = headerText.components(separatedBy: "\r\n")
        guard let statusLine = headerLines.first else {
            throw ResolverListError.invalidHTTPResponse(url)
        }
        let statusParts = statusLine.split(separator: " ")
        guard statusParts.count >= 2, let status = Int(statusParts[1]) else {
            throw ResolverListError.invalidHTTPResponse(url)
        }
        guard (200..<300).contains(status) else {
            throw ResolverListError.invalidHTTPStatus(url, status)
        }

        let headers = parseHeaders(headerLines.dropFirst())
        let body = Data(response[headerRange.upperBound...])

        if headers["transfer-encoding"]?.lowercased().contains("chunked") == true {
            return try decodeChunkedBody(body, final: final, url: url)
        }

        if let lengthText = headers["content-length"]?.trimmingCharacters(in: .whitespaces),
           let contentLength = Int(lengthText) {
            if body.count >= contentLength {
                return Data(body.prefix(contentLength))
            }
            if final {
                throw ResolverListError.invalidHTTPResponse(url)
            }
            return nil
        }

        return final ? body : nil
    }

    private static func parseHeaders(_ lines: ArraySlice<String>) -> [String: String] {
        var headers: [String: String] = [:]
        for line in lines {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }
        return headers
    }

    private static func decodeChunkedBody(_ body: Data, final: Bool, url: URL) throws -> Data? {
        var cursor = body.startIndex
        var decoded = Data()
        let crlf = Data([13, 10])

        while cursor < body.endIndex {
            guard let lineRange = body[cursor...].range(of: crlf),
                  let line = String(data: body[cursor..<lineRange.lowerBound], encoding: .ascii) else {
                if final { throw ResolverListError.invalidHTTPResponse(url) }
                return nil
            }
            let sizeText = line.split(separator: ";", maxSplits: 1).first.map(String.init) ?? line
            guard let chunkSize = Int(sizeText.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else {
                throw ResolverListError.invalidHTTPResponse(url)
            }

            cursor = lineRange.upperBound
            if chunkSize == 0 {
                return decoded
            }
            guard body.distance(from: cursor, to: body.endIndex) >= chunkSize + 2 else {
                if final { throw ResolverListError.invalidHTTPResponse(url) }
                return nil
            }

            let chunkEnd = body.index(cursor, offsetBy: chunkSize)
            decoded.append(body[cursor..<chunkEnd])
            let crlfEnd = body.index(chunkEnd, offsetBy: 2)
            guard body[chunkEnd..<crlfEnd].elementsEqual(crlf) else {
                throw ResolverListError.invalidHTTPResponse(url)
            }
            cursor = crlfEnd
        }

        if final {
            throw ResolverListError.invalidHTTPResponse(url)
        }
        return nil
    }
}

private final class ResolverFetchState: @unchecked Sendable {
    private let semaphore = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private var result: Result<Data, Error>?

    func finish(_ result: Result<Data, Error>, connection: NWConnection) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        lock.unlock()

        connection.cancel()
        semaphore.signal()
    }

    func wait() -> Result<Data, Error> {
        semaphore.wait()
        lock.lock()
        let result = self.result
        lock.unlock()
        return result ?? .failure(ResolverListError.invalidHTTPResponse(URL(string: "https://prismovpn.org/")!))
    }
}
