import Foundation

/// The management server's `/app/v1/` routes. Identity comes only from the token.
enum AppAPI {
    nonisolated struct Me: Decodable, Sendable {
        let linked: Bool
        let sip: SipAccount?
    }

    enum Failure: Error {
        case status(Int)
        case notHTTP
        /// Still 401 after a refresh Keycloak accepted: the server no longer takes this realm's
        /// tokens, for example because the tenant was removed. A refused refresh is
        /// `AuthError.expired` instead.
        case rejected
    }

    private nonisolated struct DeviceBody: Encodable, Sendable {
        let platform = "ios"
        let pushToken: String
        let apnsEnvironment: String
    }

    private static let baseURL = ServerConfig.url("app/v1/")
    private static let timeoutSeconds = 10.0
    /// Ephemeral, because `/me` carries the SIP password.
    private static let session = URLSession(configuration: .ephemeral)
    /// The public tenant routes, cached as their `Cache-Control` says.
    private static let publicSession = URLSession(configuration: .default)

    /// The tenants shown in the app, sorted by name. Needs no token.
    static func tenants() async throws -> [Tenant] {
        try JSONDecoder().decode([Tenant].self, from: try await sendPublic(baseURL.appending(path: "tenants")))
    }

    /// Any tenant, hidden ones included. An unknown key throws `Failure.status(404)`.
    static func tenant(key: String) async throws -> Tenant {
        try JSONDecoder().decode(Tenant.self, from: try await sendPublic(baseURL.appending(path: "tenants/\(key)")))
    }

    static func me() async throws -> Me {
        let data = try await send(URLRequest(url: baseURL.appending(path: "me")))
        return try JSONDecoder().decode(Me.self, from: data)
    }

    static func saveDevice(pushToken: String) async throws {
        var request = URLRequest(url: deviceURL)
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(DeviceBody(pushToken: pushToken, apnsEnvironment: Device.apnsEnvironment))
        _ = try await send(request)
    }

    static func removeDevice() async throws {
        var request = URLRequest(url: deviceURL)
        request.httpMethod = "DELETE"
        _ = try await send(request)
    }

    private static var deviceURL: URL {
        baseURL.appending(path: "devices/\(Device.id)")
    }

    /// The one place that checks a token route's status: `URLSession` treats a 401 as a success.
    /// A 401 means refresh and retry once. A second 401 is `Failure.rejected`.
    private static func send(_ request: URLRequest) async throws -> Data {
        var (data, status) = try await attempt(request, forceRefresh: false)
        if status == 401 {
            (data, status) = try await attempt(request, forceRefresh: true)
            if status == 401 { throw Failure.rejected }
        }
        guard (200..<300).contains(status) else { throw Failure.status(status) }
        return data
    }

    private static func sendPublic(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = timeoutSeconds
        let (data, response) = try await publicSession.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.notHTTP }
        guard (200..<300).contains(response.statusCode) else { throw Failure.status(response.statusCode) }
        return data
    }

    private static func attempt(_ request: URLRequest, forceRefresh: Bool) async throws -> (Data, Int) {
        var request = request
        request.timeoutInterval = timeoutSeconds
        let token = try await AuthStore.shared.accessToken(forceRefresh: forceRefresh)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw Failure.notHTTP }
        return (data, response.statusCode)
    }
}
