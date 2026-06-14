import Foundation
#if canImport(CoreTelephony) && os(iOS)
import CoreTelephony
#endif

/// Detects the active mobile carrier (PLMN = MCC+MNC) so the app can pick the
/// carrier-specific resolver list from the server-driven catalog automatically,
/// instead of asking the user to choose their operator.
public enum CarrierDetector {
    /// Returns the active carrier's PLMN code (e.g. "25001" for MTS), or nil
    /// on Wi-Fi / unknown / non-iOS.
    public static func currentPLMN() -> String? {
        #if canImport(CoreTelephony) && os(iOS)
        let info = CTTelephonyNetworkInfo()
        let carriers: [CTCarrier]
        if let providers = info.serviceSubscriberCellularProviders {
            carriers = Array(providers.values)
        } else {
            carriers = []
        }
        for carrier in carriers {
            guard let mcc = carrier.mobileCountryCode,
                  let mnc = carrier.mobileNetworkCode,
                  !mcc.isEmpty, !mnc.isEmpty else { continue }
            return mcc + mnc
        }
        return nil
        #else
        return nil
        #endif
    }

    /// Picks the best resolver list for the current network from `catalog`:
    ///   - matched carrier list (by detected PLMN), else
    ///   - `yandex` (good low-latency RU default), else
    ///   - `all`.
    public static func resolvers(from catalog: AppConfigCatalog) -> [String] {
        if let plmn = currentPLMN(), let carrier = catalog.carrier(forPLMN: plmn) {
            return carrier.resolvers
        }
        if !catalog.yandex.isEmpty { return catalog.yandex }
        return catalog.all
    }

    /// Human-readable name of the detected carrier, if known.
    public static func carrierName(from catalog: AppConfigCatalog) -> String? {
        guard let plmn = currentPLMN() else { return nil }
        return catalog.carrier(forPLMN: plmn)?.name
    }
}
