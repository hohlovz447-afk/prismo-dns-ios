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
    /// On-device resolver speed calibration progress/result text (nil when idle).
    @Published public private(set) var isCalibrating = false
    @Published public private(set) var calibrationStatus: String?

    private let engine = TunnelEngine()
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
    private var lastNetworkKey: String?
    private var pruneTask: Task<Void, Never>?
    /// Watches for a UDP tunnel session after connect; if none establishes
    /// (white-list blocking :53) it transparently restarts in DoH mode.
    private var dohWatchdogTask: Task<Void, Never>?

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
        // the app never relies on hardcoded DNS data, then probe the resulting
        // candidates so connecting picks resolvers that actually work on this
        // user's network (РФ carriers block different ones). Light UDP scan.
        let settingsSnapshot = settings
        Task {
            await AppConfigService.shared.refresh()
            await ResolverListService.scanResolvers(settings: settingsSnapshot)
        }

        // Re-probe resolvers when the network changes (carrier/Wi-Fi switch or
        // new restrictions) so the working set stays valid for the new network.
        lastNetworkKey = ResolverHealthStore.shared.currentNetworkKey()
        physicalInterfaceMonitor.objectWillChange
            .debounce(for: .seconds(2), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.rescanIfNetworkChanged() }
            .store(in: &cancellables)

        // Silently re-validate the saved subscription on launch so an expired
        // or revoked token is reflected without the user re-pasting it.
        if subscriptionState?.token.isEmpty == false {
            Task {
                await revalidateSubscription()
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
    }

    /// The subscription URL (`https://.../sub/{token}`) used for the "Speed"
    /// mode. Speed servers are VLESS and require a system VPN tunnel (Network
    /// Extension), which this app does not have, so we hand the subscription
    /// off to Happ — a full VPN client that supports VLESS — instead of trying
    /// to run them here.
    public var speedSubscriptionURL: URL? {
        guard let token = subscriptionState?.token, !token.isEmpty else { return nil }
        return VlessSubscriptionService.defaultBaseURL
            .appendingPathComponent("sub")
            .appendingPathComponent(token)
    }

    /// Local SOCKS5 port the DNS tunnel is — or will be — listening on.
    /// Uses the live port while the tunnel is running, otherwise the configured
    /// one, so the Happ proxy always matches the app's current setting.
    public var localProxyPort: Int {
        activeSocksPort ?? settings.socksPort
    }

    /// The `socks://` config that points Happ at Prismo's local DNS-tunnel
    /// proxy. Uses Happ's documented "Partial Base64" SOCKS5 format
    /// (`socks://<base64(user:pass)>@host:port#name`).
    ///
    /// Happ rejects an empty credential pair (e.g. base64 of ":"), so we always
    /// embed a non-empty `user:pass`. When Prismo's SOCKS auth is disabled the
    /// local listener accepts any credentials over loopback, so these are just
    /// placeholders; when it's enabled they are the configured credentials and
    /// must match.
    public var happProxyURI: String {
        let host = "127.0.0.1"
        let port = localProxyPort
        let user = settings.socksUser.isEmpty ? "prismo" : settings.socksUser
        let pass = settings.socksPass.isEmpty ? "prismo" : settings.socksPass
        let creds = Data("\(user):\(pass)".utf8).base64EncodedString()
        return "socks://\(creds)@\(host):\(port)#Prismo"
    }

    /// Deep link that opens Happ and adds Prismo's local SOCKS5 proxy in one
    /// tap, so Happ routes all system traffic through the running DNS tunnel.
    /// Happ expects the inner config un-encoded, mirroring its other add links.
    public var happDeepLink: URL? {
        URL(string: "happ://add/\(happProxyURI)")
    }

    /// True once there is a profile to bridge — Prismo only routes system-wide
    /// traffic through an external client (Happ), so the action is shown
    /// whenever the user has at least one profile configured.
    public var canBridgeToHapp: Bool {
        !profiles.isEmpty
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
        startConnection(forceDoH: settings.forceDoHMode)
    }

    /// Starts the tunnel. `forceDoH` routes all DNS through the whitelisted DoH
    /// shim (used by the auto-fallback when plain UDP can't establish a session).
    private func startConnection(forceDoH: Bool) {
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id }) else { return }
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
        AppLogger.shared.append(forceDoH
            ? "Starting tunnel for \(profile.domain) via DoH (white-list bypass)..."
            : "Starting tunnel for \(profile.domain)...")

        startTask?.cancel()
        startTask = Task { [weak self] in
            guard let self else { return }
            let runtimeDir = self.runtimeDirectory(for: profile)
            do {
                #if os(iOS)
                try self.backgroundRuntimeKeeper.start()
                #endif
                // Load the latest server-driven catalog (resolvers + per-operator
                // tuning) BEFORE building the engine config, so the operator's
                // tuning (e.g. lower packet duplication) reliably applies on this
                // connect instead of racing the background refresh. Best-effort:
                // refresh() falls back to cache and never throws.
                await AppConfigService.shared.refresh()
                try await Task.detached(priority: .userInitiated) { [engine = self.engine] in
                    try engine.start(
                        EngineStartOptions(
                            profile: profile,
                            settings: settingsSnapshot,
                            runtimeDirectory: runtimeDir,
                            boundInterface: boundInterface,
                            boundIPv4: boundIPv4,
                            boundIPv6: boundIPv6,
                            forceDoH: forceDoH
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
                    self.startResolverHealthPruning()
                    self.armDoHFallbackWatchdog(token: token, alreadyDoH: forceDoH)
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
        pruneTask?.cancel()
        dohWatchdogTask?.cancel()
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

    // MARK: - On-device resolver speed calibration

    /// Measures real download speed for each candidate resolver on the user's
    /// actual network (sequentially, single-resolver), then pins the fastest
    /// ones as the manual resolver list. Runs only while the tunnel is stopped.
    public func calibrateResolvers() {
        guard !isCalibrating, !status.isRunning else { return }
        guard let id = selectedProfileID,
              let profile = profiles.first(where: { $0.id == id }),
              validationMessage(for: profile) == nil else {
            calibrationStatus = AppLocalization.string("Select a valid profile first.")
            return
        }

        let baseSettings = settings
        var calibSettings = baseSettings
        calibSettings.socksPort = ResolverCalibrator.calibrationPort
        calibSettings.socksAuthEnabled = false
        calibSettings.customResolvers = ""
        let configTOML = ConfigBuilder.buildTOML(for: profile, settings: calibSettings)

        let candidates = ResolverListService.candidates(settings: baseSettings)
        guard !candidates.isEmpty else {
            calibrationStatus = AppLocalization.string("No resolvers to test.")
            return
        }
        // Speed-testing is sequential (one engine instance per resolver, a few
        // seconds each), so cap the set to keep calibration to a couple of
        // minutes. The cheap UDP probe already pre-ranked these fastest-first.
        let calibrationCandidates = Array(candidates.prefix(15))

        let runtimeDir = runtimeDirectory(for: profile).appendingPathComponent("calib", isDirectory: true)
        let boundInterface = physicalInterfaceMonitor.currentName
        let boundIPv4 = physicalInterfaceMonitor.currentIPv4
        let boundIPv6 = physicalInterfaceMonitor.currentIPv6

        isCalibrating = true
        calibrationStatus = AppLocalization.format("Testing resolvers… %d / %d", 0, calibrationCandidates.count)
        AppLogger.shared.append("Resolver calibration started (\(calibrationCandidates.count) candidates).")

        Task { [weak self] in
            let samples = await ResolverCalibrator.calibrate(
                configTOML: configTOML,
                candidates: calibrationCandidates,
                runtimeDirectory: runtimeDir,
                boundInterface: boundInterface,
                boundIPv4: boundIPv4,
                boundIPv6: boundIPv6,
                progress: { done, total, _ in
                    Task { @MainActor in
                        self?.calibrationStatus = AppLocalization.format("Testing resolvers… %d / %d", done, total)
                    }
                }
            )
            await MainActor.run { self?.finishCalibration(samples: samples) }
        }
    }

    private func finishCalibration(samples: [ResolverCalibrator.Sample]) {
        isCalibrating = false
        let alive = samples.filter { $0.bytesPerSec > 0 }
        // A wide parallel channel needs several working resolvers. If too few
        // passed, keep the full wide pool rather than narrowing — one resolver
        // caps throughput low and kills the balancer's parallelism.
        guard alive.count >= 3 else {
            calibrationStatus = AppLocalization.format(
                "Only %d resolver(s) passed — keeping the full pool. Add more resolvers for higher speed.",
                alive.count
            )
            AppLogger.shared.append("Resolver calibration: only \(alive.count) passed; keeping wide pool.")
            return
        }
        // Keep ALL working resolvers, fastest-first, so the engine balances
        // across them in parallel (wider channel, dodges per-resolver limits).
        settings.customResolvers = alive.map(\.resolver).joined(separator: "\n")
        saveSettings()
        let bestMbps = alive[0].kbitsPerSec / 1000.0
        calibrationStatus = AppLocalization.format("Kept %d fastest resolvers (best %.1f Mbit/s).", alive.count, bestMbps)
        AppLogger.shared.append("Resolver calibration done: kept \(alive.count), best \(String(format: "%.1f", bestMbps)) Mbit/s.")
    }

    /// Re-probes resolvers when the active network changes so the working set
    /// matches the new carrier/Wi-Fi (different networks block different ones).
    /// While connected, periodically reads passive per-resolver health from the
    /// engine and prunes underperformers from the persisted working set, so the
    /// app learns which resolvers actually work on this network over time.
    /// After connect, polls the engine for an established session. If none
    /// appears within the deadline — the hallmark of a white-list blocking
    /// UDP/53 — it transparently restarts the tunnel in DoH mode (whitelisted
    /// Yandex DoH over 443). Runs only for the initial UDP attempt; a DoH
    /// session is never re-fallen-back. The generous deadline ensures a normal
    /// (slow-MTU) connect never triggers it.
    private func armDoHFallbackWatchdog(token: UInt64, alreadyDoH: Bool) {
        dohWatchdogTask?.cancel()
        guard !alreadyDoH else { return }
        dohWatchdogTask = Task { [weak self] in
            guard let self else { return }
            let deadline = Date().addingTimeInterval(40)
            while !Task.isCancelled && Date() < deadline {
                try? await Task.sleep(nanoseconds: 2_500_000_000) // 2.5s
                guard self.lifecycleToken == token else { return } // superseded
                let ready = await Task.detached(priority: .utility) { [engine = self.engine] in
                    engine.isSessionReady
                }.value
                if ready { return } // UDP tunnel established — nothing to do
            }
            guard !Task.isCancelled,
                  self.lifecycleToken == token,
                  self.status == .ready else { return }
            AppLogger.shared.append("No tunnel session over UDP — switching to DoH (white-list bypass)…")
            await Task.detached(priority: .userInitiated) { [engine = self.engine] in
                engine.stop()
            }.value
            self.startConnection(forceDoH: true)
        }
    }

    private func startResolverHealthPruning() {
        pruneTask?.cancel()
        let key = ResolverHealthStore.shared.currentNetworkKey()
        pruneTask = Task { [weak self] in
            var ticks = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000) // 30s
                guard let self else { return }
                guard self.status == .ready else { continue }
                let json = await Task.detached(priority: .utility) { [engine = self.engine] in
                    engine.currentResolverStatsJSON()
                }.value
                let bad = ResolverHealth.badResolvers(fromJSON: json)
                if !bad.isEmpty {
                    ResolverHealthStore.shared.prune(bad, for: key)
                    AppLogger.shared.append("Resolver health: pruned \(bad.count) underperformer(s).")
                }
                // Every ~5 min, contribute anonymized per-resolver health to the
                // backend so the whole fleet's measurements keep the per-operator
                // lists fresh (crowd-sourced, self-maintaining). Anonymous: only
                // PLMN + loss/RTT counters, no token/user id.
                ticks += 1
                if ticks % 10 == 0 {
                    await ResolverReportService.report(statsJSON: json)
                }
            }
        }
    }

    private func rescanIfNetworkChanged() {
        let key = ResolverHealthStore.shared.currentNetworkKey()
        guard key != lastNetworkKey else { return }
        lastNetworkKey = key
        let snapshot = settings
        AppLogger.shared.append("Network changed (\(key)); re-probing resolvers.")
        Task { await ResolverListService.scanResolvers(settings: snapshot) }
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
        pruneTask?.cancel()
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
