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

        enum CodingKeys: String, CodingKey {
            case id, name
            case mccMnc = "mcc_mnc"
            case resolvers
        }
    }

    public let version: Int
    public let carriers: [Carrier]
    public let fast: [String]
    public let yandex: [String]
    public let all: [String]

    /// Returns the carrier whose MCC/MNC list contains `plmn` (e.g. "25001").
    public func carrier(forPLMN plmn: String) -> Carrier? {
        carriers.first { $0.mccMnc.contains(plmn) }
    }

    public func carrier(id: String) -> Carrier? {
        carriers.first { $0.id == id }
    }

    /// Built-in fallback used before the first successful fetch / offline.
    /// Mirrors the backend catalog (`/api/app-config`) so the operator picker
    /// is never empty and PLMN auto-detection works offline. The server
    /// overrides this whenever it is reachable.
    public static let bundledFallback = AppConfigCatalog(
        version: 0,
        carriers: [
            Carrier(id: "mts", name: "МТС", mccMnc: ["25001"],
                    resolvers: ["213.87.0.1", "213.87.1.1", "213.234.192.7", "213.234.193.7"]),
            Carrier(id: "beeline", name: "Билайн", mccMnc: ["25099"],
                    resolvers: ["194.67.2.114", "194.67.1.154", "83.69.207.105", "83.69.207.107"]),
            Carrier(id: "megafon", name: "Мегафон", mccMnc: ["25002"],
                    resolvers: ["195.208.4.1", "195.208.5.1", "85.21.192.5", "62.112.106.130"]),
            // Tele2 (25020), SberMobile (25035), Tinkoff/T-Mobile (25062) ride Tele2.
            Carrier(id: "tele2", name: "Т2", mccMnc: ["25020", "25035", "25062"],
                    resolvers: ["176.59.31.182", "176.59.31.183", "217.65.2.10", "217.65.5.10"]),
            // Yota runs on Megafon's core (25011).
            Carrier(id: "yota", name: "Yota", mccMnc: ["25011"],
                    resolvers: ["195.208.4.1", "195.208.5.1", "77.88.8.8", "77.88.8.1"]),
            Carrier(id: "volna", name: "Волна мобайл", mccMnc: ["25015"],
                    resolvers: ["77.88.8.8", "77.88.8.1", "1.1.1.1", "8.8.8.8"]),
        ],
        fast: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"],
        yandex: ["77.88.8.8", "77.88.8.1", "77.88.8.88", "77.88.8.2", "77.88.8.7", "77.88.8.3"],
        all: ["77.88.8.8", "77.88.8.1", "77.88.8.88", "77.88.8.2", "77.88.8.7", "77.88.8.3"]
    )
}
