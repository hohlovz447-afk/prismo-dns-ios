import Combine
import Foundation
import SwiftUI

@MainActor
public final class ClientViewModel: ObservableObject {
    @Published public private(set) var profiles: [ConnectionProfile] = []
    @Published public var selectedProfileID: UUID?
    @Published public var draft: ConnectionProfile = .empty
    @Published public var settings: AppSettings
    @Published public private(set) var status: ClientStatus = .stopped
    @Published public private(set) var logs: [String] = []
    @Published public private(set) var isImporting = false
    @Published public var importErrorMessage: String?
    @Published public private(set) var activeSocksPort: Int?
    @Published public private(set) var pingingProfileIDs: Set<UUID> = []
    @Published public private(set) var pingResults: [UUID: ProfilePingResult] = [:]
    /// Last known state of the user's subscription (token + expiry + status).
    @Published public private(set) var subscriptionState: SubscriptionState?
    @Published public private(set) var isCheckingSubscription = false
    /// Regular VLESS servers from the subscription ("Speed" mode). Shown below
    /// the "Обход 🐌🐌" tunnel profile. Connecting to these needs the VLESS
    /// engine (not yet built), so the UI marks them as coming soon.
    @Published public private(set) var vlessServers: [VlessServer] = []
    @Published public private(set) var isLoadingVlessServers = false
    /// Currently connected VLESS server (Speed mode), if any.
    @Published public private(set) var activeVlessServerID: UUID?

    private let engine = TunnelEngine()
    private let vlessEngine = VlessEngine()
    #if os(iOS)
    private let backgroundRuntimeKeeper = BackgroundRuntimeKeeper()
    #endif
    private let profileStore = ProfileStore.shared
    private let settingsStore = AppSettingsStore.shared
    private let subscriptionStore = SubscriptionStore.shared
    private let pinger = ProfilePinger()
    public let physicalInterfaceMonitor = PhysicalInterfaceMonitor()
    private var cancellables = Set<AnyCancellable>()
    private var startTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var pingTasks: [UUID: Task<Void, Never>] = [:]
    private var lifecycleToken: UInt64 = 0

    /// Legacy display names of the DNS-tunnel profile, migrated to
    /// ``ConnectionProfile/bypassProfileName`` on load.
    private static let legacyBypassNames: Set<String> = ["Prismo", "Prismo DNS", "Prismo Obhod"]

    public init() {
        settings = AppSettingsStore.shared.load()
        profiles = profileStore.load()
        Self.migrateBypassNames(&profiles)
        profiles = Self.sortBypassFirst(profiles)
        selectedProfileID = profiles.first?.id
        if let selected = profiles.first { draft = selected }
        subscriptionState = subscriptionStore.load()

        AppLogger.shared.$lines
            .receive(on: DispatchQueue.main)
            .sink { [weak self] lines in self?.logs = lines }
            .store(in: &cancellables)

        physicalInterfaceMonitor.start()

        // Refresh the server-driven config catalog (resolvers per carrier) so
        // the app never relies on hardcoded DNS data.
        Task { await AppConfigService.shared.refresh() }

        // Silently re-validate the saved subscription on launch so an expired
        // or revoked token is reflected without the user re-pasting it, and
        // load the regular VLESS servers for "Speed" mode.
        if subscriptionState?.token.isEmpty == false {
            Task {
                await revalidateSubscription()
                await loadVlessServers()
            }
        }
    }

    /// Re-checks the stored token against the backend and refreshes the
    /// profile (domain/key may have rotated server-side). Safe to call
    /// repeatedly; never throws — failures fall back to the last known state.
    public func revalidateSubscription() async {
        guard let token = subscriptionState?.token, !token.isEmpty else { return }
        isCheckingSubscription = true
        defer { isCheckingSubscription = false }

        do {
            let verified = try await PrismoTokenService.verify(token: token)
            applyVerified(verified)
            AppLogger.shared.append("Subscription active until \(verified.expiresAt.map { Self.dateString($0) } ?? "?").")
        } catch let error as PrismoTokenService.TokenError {
            switch error {
            case .invalidToken:
                updateSubscriptionStatus(.invalid)
                AppLogger.shared.append("Subscription token is no longer valid.")
            case .expired:
                updateSubscriptionStatus(.expired)
                AppLogger.shared.append("Subscription has expired.")
            default:
                updateSubscriptionStatus(.unknown)
            }
        } catch {
            updateSubscriptionStatus(.unknown)
        }
    }

    private func applyVerified(_ verified: PrismoTokenService.VerifiedSubscription) {
        var state = subscriptionState ?? SubscriptionState(token: verified.token)
        state.token = verified.token
        state.status = .active
        state.expiresAt = verified.expiresAt
        state.lastCheckedAt = Date()
        subscriptionState = state
        subscriptionStore.save(state)

        // Keep the auto-imported bypass profile in sync with the latest config.
        if let idx = profiles.firstIndex(where: { isBypassProfile($0) }) {
            profiles[idx].domain = verified.profile.domain
            profiles[idx].encryptionKey = verified.profile.encryptionKey
            profiles[idx].encryptionMethod = verified.profile.encryptionMethod
            persistProfiles()
        }
    }

    private func updateSubscriptionStatus(_ status: SubscriptionStatus) {
        guard var state = subscriptionState else { return }
        state.status = status
        state.lastCheckedAt = Date()
        subscriptionState = state
        subscriptionStore.save(state)
    }

    private static func dateString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Renames any legacy DNS-tunnel profile to the new "Обход 🐌🐌" label so
    /// existing installs pick up the rename on next launch.
    private static func migrateBypassNames(_ profiles: inout [ConnectionProfile]) {
        for i in profiles.indices where legacyBypassNames.contains(profiles[i].name) {
            profiles[i].name = ConnectionProfile.bypassProfileName
        }
    }

    /// True when `profile` is the DNS-tunnel ("bypass") profile.
    public func isBypassProfile(_ profile: ConnectionProfile) -> Bool {
        profile.name == ConnectionProfile.bypassProfileName
            || Self.legacyBypassNames.contains(profile.name)
    }

    public var selectedProfileName: String {
        profiles.first(where: { $0.id == selectedProfileID })?.displayName ?? AppLocalization.string("No profile")
    }

    public var canStart: Bool {
        guard !status.isRunning, selectedProfileID != nil else { return false }
        return validationMessage == nil
    }

    public var validationMessage: String? {
        validationMessage(for: draft)
    }

    public func validationMessage(for profile: ConnectionProfile) -> String? {
        let domain = profile.domain.trimmingCharacters(in: .whitespacesAndNewlines)
        if domain.isEmpty { return AppLocalization.string("Domain is required.") }
        if !domain.contains(".") {
            return AppLocalization.string("Domain must be a delegated subdomain (e.g. v.example.com).")
        }
        if profile.encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return AppLocalization.string("Encryption key is required.")
        }
        if !AppSettings.socksPortRange.contains(settings.socksPort) {
            return AppLocalization.string("SOCKS port must be between 1024 and 65535.")
        }
        return nil
    }

    public func selectProfile(_ id: UUID) {
        selectedProfileID = id
        if let profile = profiles.first(where: { $0.id == id }) { draft = profile }
    }

    public func importProfile(domain: String, encryptionKey: String, name: String?) {
        let trimmedDomain = domain
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
        let trimmedKey = encryptionKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedDomain.isEmpty else {
            importErrorMessage = AppLocalization.string("Domain is required.")
            return
        }
        guard trimmedDomain.contains(".") else {
            importErrorMessage = AppLocalization.string("Domain must be a delegated subdomain (e.g. v.example.com).")
            return
        }
        guard !trimmedKey.isEmpty else {
            importErrorMessage = AppLocalization.string("Encryption key is required.")
            return
        }
        isImporting = true
        defer { isImporting = false }

        let displayName = (name?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? trimmedDomain
        let profile = ConnectionProfile(
            name: displayName,
            domain: trimmedDomain,
            encryptionKey: trimmedKey
        )
        profiles.append(profile)
        selectedProfileID = profile.id
        draft = profile
        persistProfiles()
        importErrorMessage = nil
        AppLogger.shared.append("Imported profile \(displayName) (\(trimmedDomain)).")
    }

    public func shareProfile(_ profile: ConnectionProfile) {
        do {
            let link = try ProfileShareCodec.encode(profile)
            ClipboardService.copy(link)
            importErrorMessage = nil
            AppLogger.shared.append("Copied profile \(profile.displayName) to clipboard.")
        } catch {
            importErrorMessage = error.localizedDescription
        }
    }

    @discardableResult
    public func importSharedProfile(_ link: String) -> Bool {
        isImporting = true
        defer { isImporting = false }

        do {
            let profile = try ProfileShareCodec.decode(link)
            if let message = validationMessage(for: profile) {
                importErrorMessage = message
                return false
            }
            profiles.append(profile)
            selectedProfileID = profile.id
            draft = profile
            persistProfiles()
            importErrorMessage = nil
            AppLogger.shared.append("Imported shared profile \(profile.displayName) (\(profile.domain)).")
            return true
        } catch {
            importErrorMessage = error.localizedDescription
            return false
        }
    }

    /// One-tap import: fetches domain + key from the Prismo backend using only
    /// the user's access token (from the Telegram bot or a `prismodns://token`
    /// deep link). Returns nil on success, or a user-facing error message.
    @discardableResult
    public func importFromPrismoToken(_ tokenOrLink: String) async -> String? {
        isImporting = true
        defer { isImporting = false }

        do {
            let verified = try await PrismoTokenService.verify(token: tokenOrLink)
            let profile = verified.profile
            if let message = validationMessage(for: profile) {
                importErrorMessage = message
                return message
            }

            // Replace any earlier auto-imported bypass profile instead of
            // stacking duplicates on every re-import.
            if let idx = profiles.firstIndex(where: { isBypassProfile($0) }) {
                profiles[idx].name = ConnectionProfile.bypassProfileName
                profiles[idx].domain = profile.domain
                profiles[idx].encryptionKey = profile.encryptionKey
                profiles[idx].encryptionMethod = profile.encryptionMethod
                selectedProfileID = profiles[idx].id
                draft = profiles[idx]
            } else {
                profiles.append(profile)
                selectedProfileID = profile.id
                draft = profile
            }
            persistProfiles()

            // Persist the token + expiry so the app can re-validate later.
            let state = SubscriptionState(
                token: verified.token,
                status: .active,
                expiresAt: verified.expiresAt,
                lastCheckedAt: Date()
            )
            subscriptionState = state
            subscriptionStore.save(state)

            importErrorMessage = nil
            AppLogger.shared.append("Imported subscription (\(profile.domain)).")

            // Also pull the regular VLESS servers for "Speed" mode.
            Task { await loadVlessServers() }
            return nil
        } catch {
            let message = error.localizedDescription
            importErrorMessage = message
            return message
        }
    }

    /// Removes the stored subscription/token (e.g. on logout).
    public func clearSubscription() {
        subscriptionState = nil
        subscriptionStore.clear()
        vlessServers = []
    }

    /// Connects to a regular VLESS server ("Speed" mode) via the sing-box
    /// engine. Stops the DNS tunnel first if it is running.
    public func connectVless(_ server: VlessServer) {
        if status.isRunning { stop() }
        vlessStop()

        let port = settings.socksPort
        do {
            try vlessEngine.start(server: server, socksPort: port) { line in
                Task { @MainActor in AppLogger.shared.append(line) }
            }
            activeVlessServerID = server.id
            status = .ready
            activeSocksPort = port
            AppLogger.shared.append("Speed mode connected: \(server.displayName). SOCKS5 127.0.0.1:\(String(port)).")
        } catch {
            status = .failed(error.localizedDescription)
            AppLogger.shared.append("Speed mode failed: \(error.localizedDescription)")
        }
    }

    /// Stops the VLESS ("Speed") engine if active.
    public func vlessStop() {
        guard activeVlessServerID != nil else { return }
        vlessEngine.stop()
        activeVlessServerID = nil
        if status == .ready { status = .stopped }
        activeSocksPort = nil
        AppLogger.shared.append("Speed mode stopped.")
    }

    /// Loads the regular VLESS servers ("Speed" mode) from the subscription.
    /// Never throws — failures just leave the list empty.
    public func loadVlessServers() async {
        guard let token = subscriptionState?.token, !token.isEmpty else { return }
        isLoadingVlessServers = true
        defer { isLoadingVlessServers = false }
        do {
            let servers = try await VlessSubscriptionService.fetchServers(token: token)
            vlessServers = servers
            AppLogger.shared.append("Loaded \(servers.count) speed-mode server(s).")
        } catch {
            // Keep whatever we had; subscription/UA issues shouldn't be fatal.
            AppLogger.shared.append("Speed-mode servers unavailable: \(error.localizedDescription)")
        }
    }

    public func clearImportError() {
        importErrorMessage = nil
    }

    public func saveDraft() {
        guard let index = profiles.firstIndex(where: { $0.id == draft.id }) else { return }
        var sanitized = draft
        sanitized.setupPacketDuplicationCount = max(sanitized.packetDuplicationCount, min(12, sanitized.setupPacketDuplicationCount))
        profiles[index] = sanitized
        draft = sanitized
        persistProfiles()
    }

    public func saveSettings() {
        settings.socksPort = AppSettings.clampedSocksPort(settings.socksPort)
        settings.resolverProviderID = AppSettings.normalizedResolverProviderID(settings.resolverProviderID)
        settingsStore.save(settings)
    }

    public func deleteProfiles(ids: [UUID]) {
        let set = Set(ids)
        profiles.removeAll { set.contains($0.id) }
        for id in ids {
            pingingProfileIDs.remove(id)
            pingResults.removeValue(forKey: id)
            pingTasks[id]?.cancel()
            pingTasks.removeValue(forKey: id)
        }
        if let current = selectedProfileID, set.contains(current) {
            selectedProfileID = profiles.first?.id
            if let next = profiles.first { draft = next } else { draft = .empty }
            if status.isRunning { stop() }
        }
        persistProfiles()
    }

    public func pingProfile(_ id: UUID) {
        guard !pingingProfileIDs.contains(id),
              let profile = profiles.first(where: { $0.id == id }) else { return }
        pingingProfileIDs.insert(id)
        pingTasks[id]?.cancel()
        pingTasks[id] = Task { [weak self, pinger] in
            let result = await pinger.ping(profile)
            await MainActor.run {
                guard let self else { return }
                self.pingingProfileIDs.remove(id)
                self.pingResults[id] = result
                self.pingTasks.removeValue(forKey: id)
            }
        }
    }

    public func start() {
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
        // Speed mode and the DNS tunnel are mutually exclusive.
        vlessStop()
        if let message = validationMessage(for: profile) {
            status = .failed(message)
            AppLogger.shared.append("Cannot start: \(message)")
            return
        }
        // If we have a token-based subscription and it is known to be expired
        // or invalid, refuse to connect with a clear reason.
        if let sub = subscriptionState, !sub.token.isEmpty, !sub.isUsable {
            let message = sub.status == .invalid
                ? AppLocalization.string("This token is not valid.")
                : AppLocalization.string("Your subscription is expired or inactive.")
            status = .failed(message)
            AppLogger.shared.append("Cannot start: \(message)")
            return
        }
        let settingsSnapshot = settings
        let boundInterface = physicalInterfaceMonitor.currentName
        let boundIPv4 = physicalInterfaceMonitor.currentIPv4
        let boundIPv6 = physicalInterfaceMonitor.currentIPv6
        lifecycleToken &+= 1
        let token = lifecycleToken
        status = .starting
        AppLogger.shared.append("Starting tunnel for \(profile.domain)...")

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let runtimeDir = self.runtimeDirectory(for: profile)
            do {
                #if os(iOS)
                try self.backgroundRuntimeKeeper.start()
                #endif
                try await Task.detached(priority: .userInitiated) { [engine = self.engine] in
                    try engine.start(
                        EngineStartOptions(
                            profile: profile,
                            settings: settingsSnapshot,
                            runtimeDirectory: runtimeDir,
                            boundInterface: boundInterface,
                            boundIPv4: boundIPv4,
                            boundIPv6: boundIPv6
                        ),
                        log: { line in
                            Task { @MainActor in AppLogger.shared.append(line) }
                        }
                    )
                }.value

                let startAction = startCompletionAction(for: token)
                switch startAction {
                case .markReady:
                    break
                case .stopEngine:
                    await Task.detached(priority: .userInitiated) { [engine = self.engine] in
                        engine.stop()
                    }.value
                    #if os(iOS)
                    await MainActor.run { self.backgroundRuntimeKeeper.stop() }
                    #endif
                    return
                case .ignore:
                    return
                }

                await MainActor.run {
                    guard self.lifecycleToken == token else { return }
                    self.status = .ready
                    self.activeSocksPort = settingsSnapshot.socksPort
                    AppLogger.shared.append("Tunnel ready. SOCKS5 proxy at 127.0.0.1:\(settingsSnapshot.socksPort).")
                }
            } catch {
                await MainActor.run {
                    guard self.lifecycleToken == token else { return }
                    self.status = .failed(error.localizedDescription)
                    AppLogger.shared.append("Tunnel failed to start: \(error.localizedDescription)")
                    #if os(iOS)
                    self.backgroundRuntimeKeeper.stop()
                    #endif
                }
            }
        }
    }

    public func stop() {
        guard status.isRunning else { return }
        lifecycleToken &+= 1
        let token = lifecycleToken
        startTask?.cancel()
        status = .stopping
        AppLogger.shared.append("Stopping tunnel...")

        stopTask?.cancel()
        stopTask = Task { [weak self] in
            guard let self else { return }
            await Task.detached(priority: .userInitiated) { [engine = self.engine] in
                engine.stop()
            }.value
            await MainActor.run {
                guard self.lifecycleToken == token else { return }
                #if os(iOS)
                self.backgroundRuntimeKeeper.stop()
                #endif
                self.status = .stopped
                self.activeSocksPort = nil
                AppLogger.shared.append("Tunnel stopped.")
            }
        }
    }

    private func startCompletionAction(for token: UInt64) -> StartCompletionAction {
        if lifecycleToken == token && status == .starting && !Task.isCancelled {
            return .markReady
        }
        switch status {
        case .stopped, .stopping, .failed:
            return .stopEngine
        case .starting, .ready:
            return .ignore
        }
    }

    public func clearLogs() {
        AppLogger.shared.clear()
    }

    public func shutdownForAppTermination() {
        if status.isRunning {
            engine.stop()
        }
        physicalInterfaceMonitor.stop()
        #if os(iOS)
        backgroundRuntimeKeeper.stop()
        #endif
    }

    private func persistProfiles() {
        sortProfiles()
        profileStore.save(profiles)
    }

    /// Keeps the DNS-tunnel ("Обход 🐌🐌") profile pinned to the top of the
    /// list; everything else preserves its relative order.
    private func sortProfiles() {
        profiles = Self.sortBypassFirst(profiles)
    }

    private static func sortBypassFirst(_ profiles: [ConnectionProfile]) -> [ConnectionProfile] {
        func isBypass(_ p: ConnectionProfile) -> Bool {
            p.name == ConnectionProfile.bypassProfileName || legacyBypassNames.contains(p.name)
        }
        return profiles.enumerated()
            .sorted { lhs, rhs in
                let lBypass = isBypass(lhs.element)
                let rBypass = isBypass(rhs.element)
                if lBypass != rBypass { return lBypass }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func runtimeDirectory(for profile: ConnectionProfile) -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Prismo", isDirectory: true)
            .appendingPathComponent(profile.id.uuidString, isDirectory: true)
    }
}

private enum StartCompletionAction {
    case markReady
    case stopEngine
    case ignore
}
