import AppAuth
import Observation
import UIKit

/// The same in every tenant's realm. The issuer comes from the session's `Tenant`.
enum KeycloakConfig {
    static let clientId = "sipclient-ios"
    /// Must be a valid redirect URI of the Keycloak client.
    static let redirectURI = URL(string: Bundle.main.bundleIdentifier! + "://oauth/callback")!
    static let scopes = ["openid", "profile", "email", "offline_access"]
    /// A realm role or a role on this client. Shows a keypad in place of Open door during a call.
    static let debugRole = "sipclient-debug"
}

enum AuthError: Error {
    /// No session, or Keycloak answered `invalid_grant`. Nothing else counts as expired.
    case expired
    case cannotPresentLogin
}

/// Owns the Keycloak session. The wake path never comes here: a push uses `StoredLink`.
@Observable final class AuthStore: NSObject, OIDAuthStateChangeDelegate, OIDAuthStateErrorDelegate {
    static let shared = AuthStore()

    private(set) var hasSession = false
    /// Whose realm the session is in. Nil with a session only for an install from before
    /// tenants, which `AppSession` signs out.
    private(set) var tenant: Tenant?
    /// Keycloak refused the refresh token. The SIP details and the wake still work.
    private(set) var isExpired = false

    @ObservationIgnored private var authState: OIDAuthState?
    /// AppAuth needs this retained while the sheet is open.
    @ObservationIgnored private var flow: OIDExternalUserAgentSession?

    private override init() {
        super.init()
        reload()
    }

    /// Reads the stored session, unless one is already loaded. An early read can fail before
    /// the first unlock, so each foreground tries again.
    func reload() {
        guard authState == nil,
              let data = Keychain.data(.authState),
              let state = try? NSKeyedUnarchiver.unarchivedObject(ofClass: OIDAuthState.self, from: data) else { return }
        tenant = Tenant.load()
        attach(state)
    }

    /// Signs in to `tenant`'s realm. The tenant is stored only once login succeeds.
    func login(to tenant: Tenant) async throws {
        guard let presenter = Self.presenter,
              let agent = OIDExternalUserAgentIOS(presenting: presenter, prefersEphemeralSession: true) else {
            throw AuthError.cannotPresentLogin
        }
        let configuration = try await OIDAuthorizationService.discoverConfiguration(forIssuer: tenant.issuer)
        let request = OIDAuthorizationRequest(
            configuration: configuration,
            clientId: KeycloakConfig.clientId,
            clientSecret: nil,
            scopes: KeycloakConfig.scopes,
            redirectURL: KeycloakConfig.redirectURI,
            responseType: OIDResponseTypeCode,
            additionalParameters: nil
        )
        defer { flow = nil }
        let state: OIDAuthState = try await withCheckedThrowingContinuation { continuation in
            flow = OIDAuthState.authState(byPresenting: request, externalUserAgent: agent) { state, error in
                if let state {
                    continuation.resume(returning: state)
                } else {
                    continuation.resume(throwing: error ?? AuthError.cannotPresentLogin)
                }
            }
        }
        self.tenant = tenant
        tenant.save()
        attach(state)
        save()
    }

    /// A token that's fresh for the next request. `forceRefresh` is for a 401: `performAction`
    /// alone would hand back a token that still looks valid.
    func accessToken(forceRefresh: Bool = false) async throws -> String {
        guard let authState else { throw AuthError.expired }
        if forceRefresh { authState.setNeedsTokenRefresh() }
        return try await withCheckedThrowingContinuation { continuation in
            authState.performAction { token, _, error in
                if let error {
                    continuation.resume(throwing: Self.isInvalidGrant(error) ? AuthError.expired : error)
                } else if let token {
                    continuation.resume(returning: token)
                } else {
                    continuation.resume(throwing: AuthError.expired)
                }
            }
        }
    }

    /// The Keycloak user's name, from the newest ID token.
    var userName: String? {
        guard let idToken = authState?.lastTokenResponse?.idToken,
              let claims = OIDIDToken(idTokenString: idToken)?.claims else { return nil }
        return (claims["name"] ?? claims["preferred_username"]) as? String
    }

    /// Whether the user has `KeycloakConfig.debugRole`. Keycloak puts roles in the access token and
    /// by default not in the ID token. `OIDIDToken` only decodes it, which is enough to pick a screen.
    var isDebugUser: Bool {
        guard let accessToken = authState?.lastTokenResponse?.accessToken,
              let claims = OIDIDToken(idTokenString: accessToken)?.claims else { return false }
        let realmAccess = claims["realm_access"] as? [String: Any]
        let clientAccess = (claims["resource_access"] as? [String: Any])?[KeycloakConfig.clientId] as? [String: Any]
        return [realmAccess, clientAccess].contains {
            ($0?["roles"] as? [String])?.contains(KeycloakConfig.debugRole) == true
        }
    }

    /// Clears the session here at once, and asks Keycloak to end it. Nothing waits on the answer.
    func endSession() {
        let refreshToken = authState?.refreshToken
        let endpoint = authState?.lastAuthorizationResponse.request.configuration.endSessionEndpoint
        clear()

        guard let refreshToken, let endpoint else { return }
        var form = URLComponents()
        form.queryItems = [
            URLQueryItem(name: "client_id", value: KeycloakConfig.clientId),
            URLQueryItem(name: "refresh_token", value: refreshToken),
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = form.percentEncodedQuery.map { Data($0.utf8) }
        URLSession.shared.dataTask(with: request).resume()
    }

    /// Forgets the session and its tenant.
    func clear() {
        authState = nil
        tenant = nil
        hasSession = false
        isExpired = false
        Keychain.delete(.authState)
        Tenant.clear()
    }

    private func attach(_ state: OIDAuthState) {
        state.stateChangeDelegate = self
        state.errorDelegate = self
        authState = state
        hasSession = true
        isExpired = state.authorizationError.map(Self.isInvalidGrant) ?? false
    }

    private func save() {
        guard let authState,
              let data = try? NSKeyedArchiver.archivedData(withRootObject: authState, requiringSecureCoding: true) else { return }
        Keychain.set(data, for: .authState)
    }

    private nonisolated static func isInvalidGrant(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == OIDOAuthTokenErrorDomain && error.code == OIDErrorCodeOAuth.invalidGrant.rawValue
    }

    private static var presenter: UIViewController? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
    }

    // MARK: OIDAuthStateChangeDelegate

    /// Saved at once, so a rotated refresh token can't be lost.
    func didChange(_ state: OIDAuthState) {
        save()
        isExpired = state.authorizationError.map(Self.isInvalidGrant) ?? false
    }

    // MARK: OIDAuthStateErrorDelegate

    func authState(_ state: OIDAuthState, didEncounterAuthorizationError error: Error) {
        isExpired = Self.isInvalidGrant(error)
    }
}
