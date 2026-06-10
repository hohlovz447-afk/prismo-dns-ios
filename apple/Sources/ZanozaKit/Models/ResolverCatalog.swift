import Foundation

/// A selectable mobile operator in the Settings → Resolvers picker.
///
/// Backed entirely by the server-driven ``AppConfigCatalog`` — there is no
/// hardcoded resolver data and no dependency on any third-party repo. The
/// operator list updates whenever the backend catalog changes.
public struct ResolverProvider: Identifiable, Hashable {
    public let id: String
    public let displayName: String
}

public enum ResolverCatalog {
    /// Operators offered in the picker, derived from the current catalog.
    public static var providers: [ResolverProvider] {
        AppConfigService.shared.current().carriers.map {
            ResolverProvider(id: $0.id, displayName: $0.name)
        }
    }

    public static func provider(id: String) -> ResolverProvider? {
        providers.first { $0.id == id }
    }
}
