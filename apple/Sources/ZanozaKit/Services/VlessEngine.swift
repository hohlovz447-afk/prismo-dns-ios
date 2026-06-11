import Foundation

#if canImport(Singbox)
import Singbox
#endif

public enum VlessEngineError: LocalizedError {
    case frameworkMissing
    case startFailed(String)

    public var errorDescription: String? {
        switch self {
        case .frameworkMissing:
            return AppLocalization.string("Speed-mode engine is not embedded in the build.")
        case .startFailed(let message):
            return message
        }
    }
}

/// Runs a single VLESS server through the embedded sing-box core, exposing a
/// local SOCKS5 proxy on `socksPort`. This powers the app's "Speed" mode.
///
/// Like ``TunnelEngine``, this is SOCKS-only on its own; system-wide routing
/// comes from the Network Extension (added once the paid account is in place).
public final class VlessEngine {
    private let lock = NSLock()
    private var running = false

    public init() {}

    public var isRunning: Bool {
        #if canImport(Singbox)
        return SingboxIsRunning()
        #else
        lock.lock(); defer { lock.unlock() }
        return running
        #endif
    }

    public func start(server: VlessServer, socksPort: Int, log: @escaping (String) -> Void) throws {
        let json = try VlessConfigBuilder.buildJSON(for: server, socksPort: socksPort)

        #if canImport(Singbox)
        let relay = SingboxLogRelay { line in log(line) }
        // gomobile maps a Go func returning a sole `error` to an out-param
        // NSError** (like MobileStart), not a Swift `throws`.
        var startError: NSError?
        SingboxStart(json, relay, &startError)
        if let startError {
            throw VlessEngineError.startFailed(startError.localizedDescription)
        }
        lock.lock(); running = true; lock.unlock()
        #else
        _ = json
        log("Singbox framework missing; cannot start speed mode.")
        throw VlessEngineError.frameworkMissing
        #endif
    }

    public func stop() {
        #if canImport(Singbox)
        SingboxStop()
        #endif
        lock.lock(); running = false; lock.unlock()
    }
}

#if canImport(Singbox)
private final class SingboxLogRelay: NSObject, SingboxLogWriterProtocol {
    private let onLog: (String) -> Void
    init(onLog: @escaping (String) -> Void) { self.onLog = onLog }
    func writeLog(_ line: String?) {
        guard let line, !line.isEmpty else { return }
        onLog(line)
    }
}
#endif
