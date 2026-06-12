import Foundation

public final class AppSettingsStore {
    public static let shared = AppSettingsStore()

    private let fileURL: URL
    private let queue = DispatchQueue(label: "org.prismovpn.settingsstore")

    private init() {
        let fm = FileManager.default
        let dir = (try? fm.url(
            for: .documentDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? URL(fileURLWithPath: NSTemporaryDirectory())
        fileURL = dir.appendingPathComponent("settings.json")
    }

    public func load() -> AppSettings {
        queue.sync {
            guard let data = try? Data(contentsOf: fileURL),
                  let decoded = try? JSONDecoder().decode(AppSettings.self, from: data) else {
                return AppSettings()
            }
            return decoded
        }
    }

    public func save(_ settings: AppSettings) {
        queue.async {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            guard let data = try? encoder.encode(settings) else { return }
            try? data.write(to: self.fileURL, options: .atomic)
        }
    }
}
