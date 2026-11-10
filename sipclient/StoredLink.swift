import Foundation

/// The `sip` block of `GET /app/v1/me`, and what the engine registers with.
nonisolated struct SipAccount: Codable, Equatable, Sendable {
    let username: String
    let password: String
    let domain: String
    let registrar: String
    let port: Int
    let transport: String
}

/// What the app keeps of the user's link. A push reads this and never touches Keycloak.
struct StoredLink: Codable, Equatable {
    let displayName: String
    let sip: SipAccount

    static func load() -> StoredLink? {
        Keychain.data(.link).flatMap { try? JSONDecoder().decode(StoredLink.self, from: $0) }
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        Keychain.set(data, for: .link)
    }

    static func clear() {
        Keychain.delete(.link)
    }
}
