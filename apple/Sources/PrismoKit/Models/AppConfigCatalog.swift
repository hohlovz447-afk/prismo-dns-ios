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
    /// Mirrors the backend default (Yandex-first) so the tunnel still works.
    public static let bundledFallback = AppConfigCatalog(
        version: 0,
        carriers: [],
        fast: ["1.1.1.1", "1.0.0.1", "8.8.8.8", "8.8.4.4"],
        yandex: ["77.88.8.8", "77.88.8.1", "77.88.8.88", "77.88.8.2", "77.88.8.7", "77.88.8.3"],
        all: ["77.88.8.8", "77.88.8.1", "77.88.8.88", "77.88.8.2", "77.88.8.7", "77.88.8.3"]
    )
}
