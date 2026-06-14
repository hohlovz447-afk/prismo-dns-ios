import Foundation

/// Server-driven configuration catalog fetched from `GET /api/app-config`.
///
/// Holds the per-carrier resolver lists and fallbacks so the app keeps NO
/// hardcoded DNS data and no dependency on any third-party repo. Update the
/// lists on the backend → clients pick them up on next fetch, no rebuild.
public struct AppConfigCatalog: Codable, Equatable {
    public struct Carrier: Codable, Equatable, Identifiable {
        public let id: String
        public let name: String
        /// Russian PLMN codes (MCC+MNC, e.g. "25001") used to auto-detect the
        /// active operator via CoreTelephony.
        public let mccMnc: [String]
        public let resolvers: [String]
        /// Resolvers proven by the fleet to tunnel well on THIS operator (crowd-
        /// validated, may include ones outside the static `resolvers` list).
        /// Empty in older payloads/the bundled fallback.
        public let crowd: [String]

        enum CodingKeys: String, CodingKey {
            case id, name
            case mccMnc = "mcc_mnc"
            case resolvers
            case crowd
        }

        public init(id: String, name: String, mccMnc: [String], resolvers: [String], crowd: [String] = []) {
            self.id = id
            self.name = name
            self.mccMnc = mccMnc
            self.resolvers = resolvers
            self.crowd = crowd
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            name = try c.decode(String.self, forKey: .name)
            mccMnc = try c.decode([String].self, forKey: .mccMnc)
            resolvers = try c.decode([String].self, forKey: .resolvers)
            crowd = try c.decodeIfPresent([String].self, forKey: .crowd) ?? []
        }
    }

    /// Server-driven tunnel throughput tuning (optional). Lets us tune the
    /// engine's performance knobs — packet duplication, worker parallelism,
    /// ARQ window, MTU bounds — live from the backend, globally and per
    /// operator, with no app rebuild. Absent in older payloads.
    public struct Tuning: Codable, Equatable {
        public var packetDuplicationCount: Int?
        public var setupPacketDuplicationCount: Int?
        public var rxTxWorkers: Int?
        public var tunnelProcessWorkers: Int?
        public var maxPacketsPerBatch: Int?
        public var arqWindowSize: Int?
        public var maxUploadMTU: Int?
        public var maxDownloadMTU: Int?
        public var resolverBalancingStrategy: Int?

        enum CodingKeys: String, CodingKey {
            case packetDuplicationCount = "packet_duplication_count"
            case setupPacketDuplicationCount = "setup_packet_duplication_count"
            case rxTxWorkers = "rx_tx_workers"
            case tunnelProcessWorkers = "tunnel_process_workers"
            case maxPacketsPerBatch = "max_packets_per_batch"
            case arqWindowSize = "arq_window_size"
            case maxUploadMTU = "max_upload_mtu"
            case maxDownloadMTU = "max_download_mtu"
            case resolverBalancingStrategy = "resolver_balancing_strategy"
        }

        /// Returns a copy with any field set in `override` taking precedence.
        public func merged(with override: Tuning?) -> Tuning {
            guard let o = override else { return self }
            return Tuning(
                packetDuplicationCount: o.packetDuplicationCount ?? packetDuplicationCount,
                setupPacketDuplicationCount: o.setupPacketDuplicationCount ?? setupPacketDuplicationCount,
                rxTxWorkers: o.rxTxWorkers ?? rxTxWorkers,
                tunnelProcessWorkers: o.tunnelProcessWorkers ?? tunnelProcessWorkers,
                maxPacketsPerBatch: o.maxPacketsPerBatch ?? maxPacketsPerBatch,
                arqWindowSize: o.arqWindowSize ?? arqWindowSize,
                maxUploadMTU: o.maxUploadMTU ?? maxUploadMTU,
                maxDownloadMTU: o.maxDownloadMTU ?? maxDownloadMTU,
                resolverBalancingStrategy: o.resolverBalancingStrategy ?? resolverBalancingStrategy
            )
        }
    }

    public struct TuningCatalog: Codable, Equatable {
        public let defaults: Tuning?
        public let byCarrier: [String: Tuning]?

        enum CodingKeys: String, CodingKey {
            case defaults = "default"
            case byCarrier = "by_carrier"
        }
    }

    /// Server-driven DoH (DNS-over-HTTPS) upstream used by the white-list
    /// bypass. The app routes the tunnel's DNS through this whitelisted DoH
    /// endpoint when plain UDP resolvers are blocked (e.g. Tele2 home
    /// white-list). Absent in older payloads → the built-in Yandex default
    /// (`DoHConfig.yandexDefault`) is used.
    public struct DoHConfig: Codable, Equatable {
        public struct Extra: Codable, Equatable {
            public let url: String
            public let ip: String
            public let sni: String
            public let insecure: Bool
            public init(url: String, ip: String = "", sni: String = "", insecure: Bool = false) {
                self.url = url; self.ip = ip; self.sni = sni; self.insecure = insecure
            }
            public init(from decoder: Decoder) throws {
                let c = try decoder.container(keyedBy: CodingKeys.self)
                url = try c.decode(String.self, forKey: .url)
                ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
                sni = try c.decodeIfPresent(String.self, forKey: .sni) ?? ""
                insecure = try c.decodeIfPresent(Bool.self, forKey: .insecure) ?? false
            }
        }

        public let url: String
        public let ip: String
        /// Multiple upstream IPs (e.g. Yandex anycast) — one parallel DoH
        /// channel per IP for higher throughput. Falls back to `ip` when empty.
        public let ips: [String]
        public let sni: String
        public let insecure: Bool
        /// Extra heterogeneous upstreams (e.g. our own high-capacity gateway),
        /// added as additional parallel channels.
        public let extra: [Extra]

        public init(url: String, ip: String = "", ips: [String] = [], sni: String = "", insecure: Bool = false, extra: [Extra] = []) {
            self.url = url
            self.ip = ip
            self.ips = ips
            self.sni = sni
            self.insecure = insecure
            self.extra = extra
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            url = try c.decode(String.self, forKey: .url)
            ip = try c.decodeIfPresent(String.self, forKey: .ip) ?? ""
            ips = try c.decodeIfPresent([String].self, forKey: .ips) ?? []
            sni = try c.decodeIfPresent(String.self, forKey: .sni) ?? ""
            insecure = try c.decodeIfPresent(Bool.self, forKey: .insecure) ?? false
            extra = try c.decodeIfPresent([Extra].self, forKey: .extra) ?? []
        }

        /// Comma-separated IP list for the engine's DOH_UPSTREAM_IPS, or "".
        public var ipsCSV: String {
            (ips.isEmpty ? [ip] : ips).filter { !$0.isEmpty }.joined(separator: ",")
        }

        /// "url|ip|sni|insecure;..." for the engine's DOH_EXTRA_UPSTREAMS, or "".
        public var extraCSV: String {
            extra.map { "\($0.url)|\($0.ip)|\($0.sni)|\($0.insecure ? "1" : "0")" }.joined(separator: ";")
        }

        /// Yandex public DoH (AS13238, whitelisted by RU mobile operators incl.
        /// Tele2). Six anycast IPs → six parallel DoH channels for throughput.
        public static let yandexDefault = DoHConfig(
            url: "https://common.dot.dns.yandex.net/dns-query",
            ip: "77.88.8.1",
            ips: ["77.88.8.1", "77.88.8.8", "77.88.8.2", "77.88.8.3", "77.88.8.7", "77.88.8.88"],
            sni: "common.dot.dns.yandex.net",
            insecure: false
        )
    }

    public let version: Int
    public let carriers: [Carrier]
    public let fast: [String]
    public let yandex: [String]
    /// Universal resolvers known NOT to shape bandwidth — tried first.
    public let noshape: [String]
    public let all: [String]
    /// Large raw candidate pool (curated + crawler-discovered). NOT for direct
    /// use — only an on-device canary-probe source. Empty in older payloads.
    public let pool: [String]
    /// Optional server-driven throughput tuning (global + per operator).
    public let tuning: TuningCatalog?
    /// Optional server-driven DoH upstream for the white-list bypass.
    public let doh: DoHConfig?

    enum CodingKeys: String, CodingKey {
        case version, carriers, fast, yandex, noshape, all, pool, tuning, doh
    }

    public init(
        version: Int,
        carriers: [Carrier],
        fast: [String],
        yandex: [String],
        noshape: [String] = [],
        all: [String],
        pool: [String] = [],
        tuning: TuningCatalog? = nil,
        doh: DoHConfig? = nil
    ) {
        self.version = version
        self.carriers = carriers
        self.fast = fast
        self.yandex = yandex
        self.noshape = noshape
        self.all = all
        self.pool = pool
        self.tuning = tuning
        self.doh = doh
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        carriers = try c.decode([Carrier].self, forKey: .carriers)
        fast = try c.decode([String].self, forKey: .fast)
        yandex = try c.decode([String].self, forKey: .yandex)
        // Tolerate older payloads/caches that predate these fields.
        noshape = try c.decodeIfPresent([String].self, forKey: .noshape) ?? []
        all = try c.decodeIfPresent([String].self, forKey: .all) ?? []
        pool = try c.decodeIfPresent([String].self, forKey: .pool) ?? []
        tuning = try c.decodeIfPresent(TuningCatalog.self, forKey: .tuning)
        doh = try c.decodeIfPresent(DoHConfig.self, forKey: .doh)
    }

    /// Effective tunnel tuning for the current network: the global default
    /// merged with the active operator's override (pinned id wins, else PLMN).
    /// Returns nil when the catalog carries no tuning at all.
    public func resolvedTuning(plmn: String?, pinnedCarrierID: String?) -> Tuning? {
        guard let tuning else { return nil }
        var carrierID = pinnedCarrierID?.isEmpty == false ? pinnedCarrierID : nil
        if carrierID == nil, let plmn, let c = carrier(forPLMN: plmn) {
            carrierID = c.id
        }
        let override = carrierID.flatMap { tuning.byCarrier?[$0] }
        let base = tuning.defaults ?? Tuning()
        return base.merged(with: override)
    }

    /// Returns the carrier whose MCC/MNC list contains `plmn` (e.g. "25001").
    public func carrier(forPLMN plmn: String) -> Carrier? {
        carriers.first { $0.mccMnc.contains(plmn) }
    }

    public func carrier(id: String) -> Carrier? {
        carriers.first { $0.id == id }
    }

    /// Built-in fallback used before the first successful fetch / offline.
    /// Mirrors the backend catalog (`/api/app-config`) — per-operator resolver
    /// lists plus a universal non-shaping tier — so the picker is never empty
    /// and PLMN auto-detection + a good default work offline. The server
    /// overrides this whenever it is reachable.
    public static let bundledFallback = AppConfigCatalog(
        version: 0,
        carriers: [
            Carrier(id: "mts", name: "МТС", mccMnc: ["25001"], resolvers: [
                "212.188.4.10", "195.34.32.116", "213.87.0.1", "213.87.1.1",
                "213.87.142.95", "213.87.142.85", "213.87.142.94", "213.87.142.84",
                "213.87.74.21", "213.87.74.5", "213.87.211.20", "213.87.210.20",
            ]),
            Carrier(id: "beeline", name: "Билайн", mccMnc: ["25099"], resolvers: [
                "194.67.2.114", "194.67.1.154",
                "85.249.22.248", "85.249.22.249", "85.249.22.251", "85.249.22.250",
                "10.10.22.3",
            ]),
            Carrier(id: "megafon", name: "Мегафон", mccMnc: ["25002"], resolvers: [
                "84.201.166.221", "84.201.166.139", "84.201.166.50", "84.201.166.116",
                "83.169.217.22", "195.208.4.1",
                "10.112.248.238", "10.112.250.2", "10.112.248.226",
                "10.148.25.144", "10.205.171.77", "10.205.171.69",
                "10.93.233.220", "10.93.233.252", "10.10.22.3",
            ]),
            // Tele2 (25020), SberMobile (25035), Tinkoff/T-Mobile (25062) ride Tele2.
            Carrier(id: "tele2", name: "Т2", mccMnc: ["25020", "25035", "25062"], resolvers: [
                "176.59.62.125", "176.59.62.126", "176.59.31.182", "176.59.31.183",
                "176.59.223.159", "176.59.95.243", "176.59.63.148", "176.59.63.204",
                "176.59.127.156",
            ]),
            // Yota runs on Megafon's core (25011) — shares its resolvers.
            Carrier(id: "yota", name: "Yota", mccMnc: ["25011"], resolvers: [
                "84.201.166.221", "84.201.166.139", "84.201.166.50", "84.201.166.116",
                "83.169.217.22", "195.208.4.1",
                "10.112.248.238", "10.112.250.2", "10.112.248.226",
                "10.148.25.144", "10.205.171.77", "10.205.171.69",
                "10.93.233.220", "10.93.233.252",
            ]),
            Carrier(id: "volna", name: "Волна мобайл", mccMnc: ["25015"], resolvers: [
                "80.245.112.23", "195.208.4.1", "194.147.49.16",
            ]),
        ],
        fast: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"],
        yandex: ["77.88.8.8", "77.88.8.1", "77.88.8.2", "77.88.8.3", "77.88.8.7", "77.88.8.88"],
        noshape: [
            "94.25.113.230", "95.167.150.28", "91.240.86.14", "85.95.168.122",
            "185.22.235.137", "195.166.180.239", "188.0.190.35", "217.18.135.118",
            "95.167.75.62", "95.167.26.10", "46.254.19.23", "46.243.233.247",
            "81.200.149.54", "81.200.149.162", "79.174.92.201",
        ],
        all: [
            "94.25.113.230", "95.167.150.28", "91.240.86.14", "85.95.168.122",
            "185.22.235.137", "195.166.180.239", "188.0.190.35", "217.18.135.118",
            "95.167.75.62", "95.167.26.10", "46.254.19.23", "46.243.233.247",
            "81.200.149.54", "81.200.149.162", "79.174.92.201",
            "77.88.8.8", "77.88.8.1", "77.88.8.2", "77.88.8.3", "77.88.8.7", "77.88.8.88",
        ]
    )
}
