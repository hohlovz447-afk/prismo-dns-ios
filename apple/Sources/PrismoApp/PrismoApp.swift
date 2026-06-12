import PrismoKit
import SwiftUI

@main
struct PrismoApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(\.locale, AppLocalization.locale)
        }
    }
}
