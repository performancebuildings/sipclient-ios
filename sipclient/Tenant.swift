import Foundation

/// A customer organisation with its own Keycloak realm, from `GET /app/v1/tenants`. The app keeps
/// the one it signed in to; every other field the server may add is ignored.
struct Tenant: Codable, Equatable, Identifiable, Sendable {
    let key: String
    let displayName: String
    let issuer: URL

    var id: String { key }

    static func load() -> Tenant? {
        Keychain.data(.tenant).flatMap { try? JSONDecoder().decode(Tenant.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Keychain.set(data, for: .tenant)
    }

    static func clear() {
        Keychain.delete(.tenant)
    }

    private static let keyPattern = try! Regex(#"[a-z0-9]+(-[a-z0-9]+)*"#)

    /// Lowercase letters, digits and single hyphens, at most 50 characters.
    static func isValidKey(_ key: String) -> Bool {
        key.count <= 50 && key.wholeMatch(of: keyPattern) != nil
    }

    /// The key of `intercom://tenant/<key>`, or nil for any other URL. A malformed path gives an
    /// empty key, so it fails `isValidKey` and the user hears the link isn't valid.
    static func inviteKey(from url: URL) -> String? {
        guard url.scheme?.lowercased() == "intercom", url.host()?.lowercased() == "tenant" else { return nil }
        let segments = url.pathComponents.filter { $0 != "/" }
        return segments.count == 1 ? segments[0] : ""
    }
}
