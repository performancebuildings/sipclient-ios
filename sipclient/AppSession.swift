import AppAuth
import AVFAudio
import BackgroundTasks
import Observation
import UIKit

/// Everything from login to registered: which screen shows, when the app fetches its details
/// and when it registers.
@Observable final class AppSession {
    static let shared = AppSession()

    enum Screen {
        case login, loading, unreachable, notProvisioned, home
    }

    /// What `/me` last said for a user with nothing stored.
    private enum Lookup {
        case pending, failed, unlinked
    }

    enum Status: Equatable {
        case ready
        case connecting
        case failed(String?)
    }

    /// What the Login screen offers, from `GET /app/v1/tenants`.
    enum Tenants: Equatable {
        case loading
        case loaded([Tenant])
        case failed
    }

    /// What an invite link needs the user to see.
    enum InvitePrompt: Equatable, Identifiable {
        case invalid
        case unreachable
        /// Signed in to another tenant: ask before signing out.
        case confirmSwitch(from: Tenant, to: Tenant)

        var id: String {
            switch self {
            case .invalid: "invalid"
            case .unreachable: "unreachable"
            case .confirmSwitch(_, let tenant): "switch-\(tenant.key)"
            }
        }
    }

    private enum Key {
        static let lastRefresh = "session.lastRefresh"
        static let confirmedToken = "session.confirmedPushToken"
        static let isDeleteOwed = "session.isDeviceDeleteOwed"
        static let pocValues = ["sip.server", "sip.username", "sip.transport", "sip.resumeRegistration"]
    }

    /// Listed in Info.plist's `BGTaskSchedulerPermittedIdentifiers` as `$(PRODUCT_BUNDLE_IDENTIFIER).refresh`.
    static let refreshTaskIdentifier = Bundle.main.bundleIdentifier! + ".refresh"
    private static let refreshIntervalSeconds: TimeInterval = 24 * 60 * 60

    private(set) var link = StoredLink.load()
    private var lookup = Lookup.pending
    /// Why `/me` failed, under "Can't reach the server".
    private(set) var lookupFailure: String?
    private(set) var loginError: String?
    private(set) var isLoggingIn = false
    private(set) var isLoggingOut = false
    private(set) var tenants = Tenants.loading
    /// The tenant whose server stopped accepting the login, shown on the Login screen until the
    /// next login attempt.
    private(set) var rejectedTenantName: String?
    var invitePrompt: InvitePrompt?
    private(set) var isMicrophoneRefused = AVAudioApplication.shared.recordPermission == .denied
    /// The last token the server accepted. The status counts it as long as it's still this
    /// phone's token, so a failed fetch or an expired session doesn't change the status.
    private var confirmedToken = UserDefaults.standard.string(forKey: Key.confirmedToken) {
        didSet { UserDefaults.standard.set(confirmedToken, forKey: Key.confirmedToken) }
    }
    private var tokenFailure: String?
    /// Logout couldn't reach the server, so the next login sends the delete.
    private(set) var isDeleteOwed = UserDefaults.standard.bool(forKey: Key.isDeleteOwed) {
        didSet { UserDefaults.standard.set(isDeleteOwed, forKey: Key.isDeleteOwed) }
    }

    @ObservationIgnored private var foregroundWork: Task<Void, Never>?
    /// A foreground arrived during a call or wake, which must not be disturbed.
    @ObservationIgnored private var isForegroundOwed = false
    @ObservationIgnored private var hasRetriedSipLogin = false
    /// An invite link that arrived during a call or wake. Handled when it ends.
    @ObservationIgnored private var owedInvite: URL?

    private var auth: AuthStore { .shared }
    private var isOnCall: Bool { CallManager.shared.isBusy }
    private var isActive: Bool { UIApplication.shared.applicationState == .active }

    var screen: Screen {
        if link != nil { return .home }
        guard auth.hasSession else { return .login }
        switch lookup {
        case .pending: return .loading
        case .failed: return .unreachable
        case .unlinked: return .notProvisioned
        }
    }

    var needsLogin: Bool { !auth.hasSession || auth.isExpired }

    var status: Status {
        if isMicrophoneRefused { return .failed(String(localized: "Microphone access is off")) }
        let isTokenConfirmed = confirmedToken != nil && confirmedToken == PushManager.shared.token
        if !isTokenConfirmed, let tokenFailure { return .failed(tokenFailure) }
        switch SipStore.shared.state {
        case .failed: return .failed(nil)
        case .registered: return isTokenConfirmed ? .ready : .connecting
        case .notRegistered, .registering: return .connecting
        }
    }

    // MARK: Moments

    /// Launch or a return to the foreground. Stored details are on screen before this ends.
    func enterForeground() {
        removePOCData()
        auth.reload()
        link = StoredLink.load()
        if auth.hasSession, auth.tenant == nil, !Keychain.isLocked {
            // From before tenants. The server forgot its device, so there's nothing to delete.
            print("Session: no tenant stored, signing out")
            SipEngine.shared.unregister()
            forgetLink()
            auth.clear()
            lookup = .pending
        }
        guard !isOnCall else {
            isForegroundOwed = true
            return
        }
        foregroundWork?.cancel()
        foregroundWork = Task { await runForeground() }
    }

    func enterBackground() {
        let request = BGAppRefreshTaskRequest(identifier: Self.refreshTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: Self.refreshIntervalSeconds)
        do {
            try BGTaskScheduler.shared.submit(request)
        } catch {
            print("Session: refresh not scheduled: \(error)")
        }
    }

    /// Runs after the call's un-REGISTER has been sent.
    func callDidEnd() {
        if isActive {
            if isForegroundOwed {
                isForegroundOwed = false
                enterForeground()
            }
            if let url = owedInvite {
                owedInvite = nil
                openInvite(url)
            }
            return
        }
        let lastRefresh = UserDefaults.standard.object(forKey: Key.lastRefresh) as? Date ?? .distantPast
        guard Date().timeIntervalSince(lastRefresh) > Self.refreshIntervalSeconds else { return }

        let application = UIApplication.shared
        let backgroundTask = application.beginBackgroundTask(expirationHandler: nil)
        Task {
            await refreshQuietly()
            application.endBackgroundTask(backgroundTask)
        }
    }

    /// iOS decides when this runs, so nothing relies on it.
    func handleRefreshTask(_ task: BGTask) {
        enterBackground()
        let work = Task {
            await refreshQuietly()
            task.setTaskCompleted(success: true)
        }
        task.expirationHandler = { work.cancel() }
    }

    /// A token that arrives or changes in the background waits for the next foreground.
    func pushTokenChanged() {
        guard isActive, link != nil, !needsLogin else { return }
        Task { await sendToken() }
    }

    /// A foreground REGISTER got 401 or 403: the password may have changed, so fetch once.
    func sipLoginRefused() {
        guard isActive, !isOnCall, !hasRetriedSipLogin, !needsLogin, let oldAccount = link?.sip else { return }
        hasRetriedSipLogin = true
        Task {
            guard await fetchDetails(), let account = link?.sip, account != oldAccount else { return }
            SipEngine.shared.connect(account, instanceId: Device.id)
        }
    }

    // MARK: User actions

    /// From the Login screen or an invite link.
    func login(to tenant: Tenant) {
        guard !isLoggingIn else { return }
        loginError = nil
        rejectedTenantName = nil
        isLoggingIn = true
        Task {
            defer { isLoggingIn = false }
            do {
                try await auth.login(to: tenant)
                lookup = .pending
                enterForeground()
            } catch {
                // AppAuth also reports a sheet that iOS refused to open as cancelled.
                print("Session: login to \(tenant.key) ended: \(error)")
                if !Self.isCancelledLogin(error) { loginError = Self.reason(error) }
            }
        }
    }

    /// Home's prompt after Keycloak refused the refresh token: the same tenant again.
    func loginAgain() {
        guard let tenant = auth.tenant else { return }
        login(to: tenant)
    }

    /// The Login screen asks on each appearance. The answer is cached for 5 minutes.
    func loadTenants() async {
        if case .failed = tenants { tenants = .loading }
        do {
            tenants = .loaded(try await AppAPI.tenants())
        } catch {
            print("Session: tenants failed: \(error)")
            tenants = .failed
        }
    }

    /// `intercom://tenant/<key>`. Other URLs are ignored.
    func openInvite(_ url: URL) {
        guard let key = Tenant.inviteKey(from: url) else { return }
        guard !isOnCall else {
            owedInvite = url
            return
        }
        guard Tenant.isValidKey(key) else {
            invitePrompt = .invalid
            return
        }
        Task {
            let tenant: Tenant
            do {
                tenant = try await AppAPI.tenant(key: key)
            } catch AppAPI.Failure.status(404) {
                invitePrompt = .invalid
                return
            } catch {
                print("Session: invite \(key) failed: \(error)")
                invitePrompt = .unreachable
                return
            }
            if let current = auth.tenant, auth.hasSession || link != nil {
                if current.key != tenant.key { invitePrompt = .confirmSwitch(from: current, to: tenant) }
            } else {
                // A link arrives while the app is still coming forward, and iOS won't open the
                // login sheet until it's active.
                await untilActive()
                login(to: tenant)
            }
        }
    }

    private func untilActive() async {
        guard !isActive else { return }
        for await _ in NotificationCenter.default.notifications(named: UIApplication.didBecomeActiveNotification) {
            return
        }
    }

    /// The user agreed to leave their tenant for an invite's.
    func switchTenant(to tenant: Tenant) {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        foregroundWork?.cancel()
        Task {
            await signOut()
            isLoggingOut = false
            login(to: tenant)
        }
    }

    /// Try again and Check again.
    func checkAgain() {
        lookup = .pending
        enterForeground()
    }

    /// Failures never block this. `deviceId` survives it.
    func logout() {
        guard !isLoggingOut else { return }
        isLoggingOut = true
        foregroundWork?.cancel()
        Task {
            await signOut()
            isLoggingOut = false
        }
    }

    /// Deletes the device, then forgets the link, the session and its tenant.
    private func signOut() async {
        do {
            try await AppAPI.removeDevice()
            isDeleteOwed = false
        } catch AppAPI.Failure.rejected {
            // The server no longer takes this realm's tokens, so it can't take the delete later either.
            isDeleteOwed = false
        } catch {
            isDeleteOwed = true
        }
        SipEngine.shared.unregister()
        forgetLink()
        auth.endSession()
        lookup = .pending
    }

    /// A refresh worked but the server still answered 401, so it no longer accepts this tenant.
    /// Waits out a call: the stored details keep it going.
    private func signOutRejected() async {
        print("Session: token rejected after refresh, signing out")
        guard !isOnCall else {
            isForegroundOwed = true
            return
        }
        let name = auth.tenant?.displayName
        await signOut()
        rejectedTenantName = name
    }

    // MARK: Steps

    private func runForeground() async {
        hasRetriedSipLogin = false
        guard auth.hasSession || link != nil else { return }
        await sendOwedDelete()
        let isFresh = await fetchDetails()

        guard !Task.isCancelled, let account = link?.sip else { return }
        await prepareMicrophone()
        guard !Task.isCancelled, !isOnCall else { return }

        if !isMicrophoneRefused { SipEngine.shared.connect(account, instanceId: Device.id) }
        if isFresh { await sendToken() }
    }

    /// The background's version: no REGISTER and no prompts. A phone that isn't opened still
    /// picks up a changed password or an unlink here.
    private func refreshQuietly() async {
        guard !Keychain.isLocked, !isOnCall else { return }
        auth.reload()
        link = StoredLink.load()
        guard link != nil, !needsLogin else { return }
        if await fetchDetails() { await sendToken() }
    }

    /// Returns true if the server has just said the user is linked. Without an answer, the
    /// stored details stay in use and the next foreground tries again.
    private func fetchDetails() async -> Bool {
        do {
            let me = try await AppAPI.me()
            guard !Task.isCancelled else { return false }
            guard !isOnCall else {
                isForegroundOwed = true
                return false
            }
            UserDefaults.standard.set(Date(), forKey: Key.lastRefresh)
            guard me.linked, let sip = me.sip else {
                await unlink()
                return false
            }
            let newLink = StoredLink(displayName: auth.userName ?? link?.displayName ?? "", sip: sip)
            if newLink != link {
                newLink.save()
                link = newLink
            }
            return true
        } catch AppAPI.Failure.rejected {
            await signOutRejected()
            return false
        } catch AuthError.expired {
            // Stored details keep working, and Home shows the prompt. Without them there's
            // nothing to keep, so this is a plain Login.
            if link == nil { auth.clear() }
            return false
        } catch {
            guard !Task.isCancelled else { return false }
            print("Session: /me failed: \(error)")
            if link == nil {
                lookup = .failed
                lookupFailure = Self.reason(error)
            } else {
                tokenFailure = Self.reason(error)
            }
            return false
        }
    }

    private func unlink() async {
        lookup = .unlinked
        guard link != nil else { return }
        SipEngine.shared.unregister()
        forgetLink()
        do {
            try await AppAPI.removeDevice()
        } catch {
            isDeleteOwed = true
        }
    }

    private func forgetLink() {
        StoredLink.clear()
        link = nil
        confirmedToken = nil
        tokenFailure = nil
    }

    private func sendOwedDelete() async {
        guard isDeleteOwed, !needsLogin else { return }
        do {
            try await AppAPI.removeDevice()
            isDeleteOwed = false
        } catch {
            print("Session: owed device delete failed: \(error)")
        }
    }

    private func sendToken() async {
        guard let token = PushManager.shared.token else { return }
        do {
            try await AppAPI.saveDevice(pushToken: token)
            confirmedToken = token
            tokenFailure = nil
        } catch AppAPI.Failure.rejected {
            await signOutRejected()
        } catch {
            if !Task.isCancelled { tokenFailure = Self.reason(error) }
        }
    }

    /// Asks once. With the microphone refused the app skips its foreground REGISTER, but door
    /// calls still wake the phone and ring.
    private func prepareMicrophone() async {
        if AVAudioApplication.shared.recordPermission == .undetermined {
            _ = await AVAudioApplication.requestRecordPermission()
        }
        isMicrophoneRefused = AVAudioApplication.shared.recordPermission == .denied
    }

    /// Deleted, not migrated.
    private func removePOCData() {
        Keychain.delete(.pocPassword)
        for key in Key.pocValues { UserDefaults.standard.removeObject(forKey: key) }
    }

    private static func isCancelledLogin(_ error: Error) -> Bool {
        let error = error as NSError
        return error.domain == OIDGeneralErrorDomain && error.code == OIDErrorCode.userCanceledAuthorizationFlow.rawValue
    }

    private static func reason(_ error: Error) -> String {
        switch error {
        case AppAPI.Failure.status(let code): String(localized: "The server answered \(code)")
        case AuthError.expired: String(localized: "Session expired")
        case AuthError.cannotPresentLogin: String(localized: "Couldn't open the login page")
        default: error.localizedDescription
        }
    }
}
