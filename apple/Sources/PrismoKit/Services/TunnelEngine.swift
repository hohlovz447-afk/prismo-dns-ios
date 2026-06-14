import Foundation

#if canImport(Mobile)
import Mobile
#endif

public enum TunnelEngineError: LocalizedError {
    case frameworkMissing
    case invalidProfile(String)
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return AppLocalization.string("Core engine is not embedded in the build.")
        case .invalidProfile(let message):
            return message
        case .startFailed(let message):
            return message
        }
    }
}

public struct EngineStartOptions {
    public let profile: ConnectionProfile
    public let settings: AppSettings
    public let runtimeDirectory: URL
    public let boundInterface: String
    public let boundIPv4: String
    public let boundIPv6: String
    /// When true, the engine config is built with a whitelisted DoH upstream
    /// and all tunnel DNS is routed through the in-process DoH shim.
    public let forceDoH: Bool

    public init(
        profile: ConnectionProfile,
        settings: AppSettings,
        runtimeDirectory: URL,
        boundInterface: String = "",
        boundIPv4: String = "",
        boundIPv6: String = "",
        forceDoH: Bool = false
    ) {
        self.profile = profile
        self.settings = settings
        self.runtimeDirectory = runtimeDirectory
        self.boundInterface = boundInterface
        self.boundIPv4 = boundIPv4
        self.boundIPv6 = boundIPv6
        self.forceDoH = forceDoH
    }
}

public final class TunnelEngine {
    private let lock = NSLock()
    private var currentSocksPort: Int?
    #if canImport(Mobile)
    private var logRelay: MobileLogRelay?
    #endif

    public init() {}

    deinit {
        #if canImport(Mobile)
        MobileStop()
        MobileSetLogWriter(nil)
        #endif
    }

    public var isRunning: Bool {
        #if canImport(Mobile)
        return MobileIsRunning()
        #else
        return false
        #endif
    }

    public var activeSocksPort: Int? {
        lock.lock(); defer { lock.unlock() }
        return currentSocksPort
    }

    /// Passive per-resolver health from the engine as JSON (no probing), for
    /// on-device pruning of the working set. "[]" when not running.
    public func currentResolverStatsJSON() -> String {
        #if canImport(Mobile)
        return MobileGetResolverStats()
        #else
        return "[]"
        #endif
    }

    /// True once the running tunnel has an established session and can carry
    /// traffic. Used by the app's DoH auto-fallback watchdog.
    public var isSessionReady: Bool {
        #if canImport(Mobile)
        return MobileSessionReady()
        #else
        return false
        #endif
    }

    public func start(_ options: EngineStartOptions, log: @escaping (String) -> Void) throws {
        try validate(options.profile, settings: options.settings)

        let configTOML = ConfigBuilder.buildTOML(for: options.profile, settings: options.settings, forceDoH: options.forceDoH)
        let resolvers = try ResolverListService.resolve(settings: options.settings)

        let fm = FileManager.default
        try fm.createDirectory(at: options.runtimeDirectory, withIntermediateDirectories: true)

        #if canImport(Mobile)
        let relay = MobileLogRelay { line in log(line) }
        lock.lock(); logRelay = relay; lock.unlock()
        MobileSetLogWriter(relay)

        // Re-apply the bound interface AND its source IP right before Start
        // so the very first outbound socket (MTU probe) already bypasses any
        // third-party VPN — both via IP_BOUND_IF and via source-IP binding.
        MobileSetBoundInterface(options.boundInterface)
        MobileSetBoundAddress(options.boundIPv4, options.boundIPv6)

        var startError: NSError?
        let didStart = MobileStart(configTOML, resolvers, options.runtimeDirectory.path, &startError)
        if !didStart {
            MobileStop()
            MobileSetLogWriter(nil)
            lock.lock(); logRelay = nil; lock.unlock()
            let message = startError?.localizedDescription
                ?? AppLocalization.string("Failed to start the tunnel.")
            throw TunnelEngineError.startFailed(message)
        }
        lock.lock(); currentSocksPort = options.settings.socksPort; lock.unlock()
        #else
        _ = configTOML
        _ = resolvers
        log("Mobile framework missing; cannot start tunnel.")
        throw TunnelEngineError.frameworkMissing
        #endif
    }

    public func stop() {
        #if canImport(Mobile)
        MobileStop()
        MobileSetLogWriter(nil)
        #endif
        lock.lock()
        currentSocksPort = nil
        #if canImport(Mobile)
        logRelay = nil
        #endif
        lock.unlock()
    }

    private func validate(_ profile: ConnectionProfile, settings: AppSettings) throws {
        let trimmedDomain = profile.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomain.isEmpty else {
            throw TunnelEngineError.invalidProfile(AppLocalization.string("Domain is required."))
        }
        guard trimmedDomain.contains(".") else {
            throw TunnelEngineError.invalidProfile(AppLocalization.string("Domain must be a delegated subdomain (e.g. v.example.com)."))
        }
        guard !profile.encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw TunnelEngineError.invalidProfile(AppLocalization.string("Encryption key is required."))
        }
        guard AppSettings.socksPortRange.contains(settings.socksPort) else {
            throw TunnelEngineError.invalidProfile(AppLocalization.string("SOCKS port must be between 1024 and 65535."))
        }
    }
}

#if canImport(Mobile)
private final class MobileLogRelay: NSObject, MobileLogWriterProtocol {
    private let onLog: (String) -> Void

    init(onLog: @escaping (String) -> Void) {
        self.onLog = onLog
    }

    func writeLog(_ line: String?) {
        guard let line, !line.isEmpty else { return }
        onLog(line)
    }
}
#endif
