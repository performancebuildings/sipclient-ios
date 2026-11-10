import AVFAudio
@preconcurrency import CallKit
import UIKit

/// Bridges pjsip calls to CallKit. Runs on main, and only reaches pjsip through `SipEngine`.
/// CallKit owns the audio session: the app sets the session category but never calls
/// `setActive`, and pjsip opens its sound device only in `didActivate`.
final class CallManager: NSObject, CXProviderDelegate {
    static let shared = CallManager()

    private struct Call {
        let uuid: UUID
        /// Nil until the INVITE arrives after a push.
        var id: pjsua_call_id?
        /// The push's token for the status route. A call with no push has none.
        var token: String?
        var isAnswered = false
        /// An Accept tapped before the INVITE, fulfilled once there is a call to answer.
        var heldAnswer: CXAnswerCallAction?
    }

    private static let doorDigits = "#"
    /// A little longer than the server's 12 s, so the phone doesn't give up just before an INVITE.
    private static let wakeLimitSeconds = 15.0
    /// The server's 12 s wake budget plus its 30 s ring. Generous, because `sentAt` is on the
    /// server's clock: a polled wake hears `over` long before this anyway.
    private static let ringWindowSeconds = 42.0
    /// After a successful wake the server hears nothing more, so a caller who gave up shows
    /// only as an INVITE that never comes. `intercom-server` dials as soon as the wake answers.
    private static let inviteLimitSeconds = 5.0
    private static let unregisterGraceSeconds = 2.0

    private let provider: CXProvider
    private let controller = CXCallController()
    private var call: Call?
    /// A push declined before its INVITE, so a late INVITE is rejected without ringing.
    private var declined: (uuid: UUID, until: Date)?
    private var statusPoll: Task<Void, Never>?

    /// True from a push or INVITE until the call or wake ends.
    var isBusy: Bool { call != nil }

    private static var providerConfiguration: CXProviderConfiguration {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.iconTemplateImageData = UIImage(systemName: "video.fill")?.pngData()
        return configuration
    }

    override init() {
        provider = CXProvider(configuration: Self.providerConfiguration)
        super.init()
        provider.setDelegate(self, queue: nil)
    }

    /// Sets up the audio session without activating it.
    func prepareAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setCategory(.playAndRecord, mode: .videoChat)
        } catch {
            print("CallKit: audio session setup failed: \(error)")
        }
    }

    /// Reports a push's call before returning, as PushKit requires, then starts SIP alongside
    /// the ring. A phone already on a call is allowed not to report, and declines instead.
    func reportPush(_ push: WakePush, completion: @escaping () -> Void) {
        let uuid = push.uuid
        guard !isBusy else {
            // The same UUID means the INVITE came first, because a foreground REGISTER looks
            // like a wake to the server. That's this call, so it must not be declined.
            if call?.uuid != uuid {
                print("CallKit: push while on a call")
                decline(uuid, token: push.callToken)
            }
            completion()
            return
        }
        call = Call(uuid: uuid, id: nil, token: push.callToken)
        declined = nil
        SipStore.shared.setCall(CallDisplay(caller: push.caller, isConnected: false))

        provider.configuration = Self.providerConfiguration
        provider.reportNewIncomingCall(with: uuid, update: Self.update(caller: push.caller)) { error in
            onMain { [self] in
                if let error {
                    WakeTimeline.shared.mark("report refused: \(String(describing: error))")
                    refuseWake(push)
                } else {
                    WakeTimeline.shared.mark("reported")
                    startWake(push)
                }
                completion()
            }
        }
    }

    /// CallKit refused the report, for example under Do Not Disturb. Nothing rings, so the
    /// caller hears now, with no REGISTER. Runs before PushKit's completion: iOS suspends the
    /// app straight after it.
    private func refuseWake(_ push: WakePush) {
        guard let current = call, current.uuid == push.uuid else { return }
        decline(push.uuid, token: push.callToken)
        if let id = current.id { SipEngine.shared.hangUp(id, code: 486) }
        clearCall(push.uuid)
    }

    private func startWake(_ push: WakePush) {
        let uuid = push.uuid
        guard call?.uuid == uuid, call?.id == nil else { return }

        if let sentAt = push.sentAt, Date().timeIntervalSince(sentAt) > Self.ringWindowSeconds {
            endWake(uuid, reason: .remoteEnded, mark: "past the ring window")
            return
        }
        guard let link = StoredLink.load() else {
            print("CallKit: no stored account")
            decline(uuid, token: push.callToken)
            endWake(uuid, reason: .failed, mark: "no stored details")
            return
        }
        SipEngine.shared.wake(link.sip, instanceId: Device.id)
        if let token = push.callToken { pollStatus(uuid, token: token) }
        endWake(uuid, after: Self.wakeLimitSeconds, reason: .failed, mark: "wake limit")
    }

    /// Runs until the INVITE arrives, the answer is `over` or the wake ends. A cancel can't
    /// reach a waking phone over SIP, so this is how it hears.
    private func pollStatus(_ uuid: UUID, token: String) {
        statusPoll = Task { [self] in
            while !Task.isCancelled {
                do {
                    if try await WakeAPI.send(.waiting, uuid: uuid, token: token) == .over {
                        endWake(uuid, reason: .remoteEnded, mark: "server says over")
                        return
                    }
                } catch {
                    print("Wake: status failed: \(error)")
                }
                try? await Task.sleep(for: .seconds(WakeAPI.pollSeconds))
            }
        }
    }

    /// The REGISTER the server was waiting for has landed, so the INVITE should follow.
    func wakeRegistered() {
        guard let current = call, current.id == nil else { return }
        endWake(current.uuid, after: Self.inviteLimitSeconds, reason: .remoteEnded, mark: "no INVITE after REGISTER")
    }

    private func endWake(_ uuid: UUID, after seconds: TimeInterval, reason: CXCallEndedReason, mark: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [self] in
            MainActor.assumeIsolated { endWake(uuid, reason: reason, mark: mark) }
        }
    }

    /// Does nothing once the wake has its INVITE or has already ended.
    private func endWake(_ uuid: UUID, reason: CXCallEndedReason, mark: String) {
        guard let current = call, current.uuid == uuid, current.id == nil else { return }
        WakeTimeline.shared.mark("wake ended: \(mark)")
        current.heldAnswer?.fail()
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        clearCall(uuid)
    }

    /// Tells the server, and rejects the INVITE if it arrives anyway.
    private func decline(_ uuid: UUID, token: String?) {
        declined = (uuid, Date().addingTimeInterval(Self.wakeLimitSeconds))
        if let token { WakeAPI.decline(uuid: uuid, token: token) }
    }

    private static func update(caller: String) -> CXCallUpdate {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: caller)
        update.localizedCallerName = caller
        update.hasVideo = true
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        update.supportsDTMF = false
        return update
    }

    /// Un-REGISTERs when the app is in the background with no call or wake active.
    func unregisterIfIdle() {
        guard call == nil, UIApplication.shared.applicationState != .active else { return }
        let application = UIApplication.shared
        let task = application.beginBackgroundTask(expirationHandler: nil)
        SipEngine.shared.pause()
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.unregisterGraceSeconds) {
            application.endBackgroundTask(task)
        }
    }

    /// `callUUID` is the INVITE's `X-PB-Call-UUID`. Without one, the INVITE is taken as the
    /// pending call, which is enough for one device.
    func reportIncoming(id: pjsua_call_id, caller: String, callUUID: UUID?) {
        WakeTimeline.shared.mark("INVITE")
        if let declined, declined.until > Date(), callUUID == nil || callUUID == declined.uuid {
            print("CallKit: rejecting the INVITE of a declined push")
            self.declined = nil
            SipEngine.shared.hangUp(id, code: 603)
            return
        }
        if let pending = call, pending.id == nil {
            if callUUID == nil || callUUID == pending.uuid {
                attachInvite(id, caller: caller, to: pending)
            } else {
                print("CallKit: rejecting an INVITE for another call")
                SipEngine.shared.hangUp(id, code: 486)
            }
            return
        }

        let uuid = callUUID ?? UUID()
        call = Call(uuid: uuid, id: id)
        SipStore.shared.setCall(CallDisplay(caller: caller, isConnected: false))

        let update = Self.update(caller: caller)

        // Setting the configuration before each report works around the missing
        // `didActivate` bug on iOS 26.5.
        provider.configuration = Self.providerConfiguration
        Task {
            do {
                try await provider.reportNewIncomingCall(with: uuid, update: update)
                print("CallKit: reported call \(id)")
                SipEngine.shared.ring(id)
            } catch {
                print("CallKit: report refused: \(error)")
                clearCall(uuid)
                SipEngine.shared.hangUp(id, code: 486)
            }
        }
    }

    private func attachInvite(_ id: pjsua_call_id, caller: String, to pending: Call) {
        call?.id = id
        statusPoll?.cancel()
        provider.reportCall(with: pending.uuid, updated: Self.update(caller: caller))
        guard let action = pending.heldAnswer else {
            SipEngine.shared.ring(id)
            return
        }
        call?.heldAnswer = nil
        answer(id, action: action)
    }

    private func answer(_ id: pjsua_call_id, action: CXAnswerCallAction) {
        SipEngine.shared.answer(id) { isAnswered in
            onMain {
                print("CallKit: answer \(isAnswered ? "fulfilled" : "failed")")
                if isAnswered { action.fulfill() } else { action.fail() }
            }
        }
    }

    func callConnected(id: pjsua_call_id) {
        guard call?.id == id else { return }
        SipStore.shared.markCallConnected()
    }

    func audioActive(id: pjsua_call_id) {
        guard call?.id == id else { return }
        SipStore.shared.markAudioActive()
    }

    /// Sends the Open door Action. `completion` runs on main with a failure reason, or nil.
    func openDoor(completion: @escaping @MainActor (String?) -> Void) {
        sendDigits(Self.doorDigits, completion: completion)
    }

    /// Sends DTMF digits. `completion` runs on main with a failure reason, or nil.
    func sendDigits(_ digits: String, completion: @escaping @MainActor (String?) -> Void) {
        guard let id = call?.id else { return }
        SipEngine.shared.sendDigits(id, digits) { failure in
            onMain { completion(failure) }
        }
    }

    /// The SIP side ended the call. Calls the user ended are already cleared, so they
    /// are not reported twice.
    func callEnded(id: pjsua_call_id, lastStatus: Int) {
        guard let call, call.id == id else {
            // The SIP side only counts as idle from here, so the app's own hang-up ends up here too.
            unregisterIfIdle()
            return
        }
        let reason: CXCallEndedReason = [408, 480].contains(lastStatus) ? .unanswered : .remoteEnded
        print("CallKit: remote end, status \(lastStatus)")
        provider.reportCall(with: call.uuid, endedAt: Date(), reason: reason)
        clearCall(call.uuid)
    }

    /// Hang-up from the app's own button; it takes the same path as the system UI.
    func endCall() {
        guard let call else { return }
        controller.request(CXTransaction(action: CXEndCallAction(call: call.uuid))) { error in
            if let error { print("CallKit: end request failed: \(error)") }
        }
    }

    private func clearCall(_ uuid: UUID) {
        guard call?.uuid == uuid else { return }
        call = nil
        statusPoll?.cancel()
        SipStore.shared.setCall(nil)
        unregisterIfIdle()
        AppSession.shared.callDidEnd()
    }

    // MARK: CXProviderDelegate

    func providerDidReset(_ provider: CXProvider) {
        print("CallKit: provider reset")
        if let call {
            if let id = call.id { SipEngine.shared.hangUp(id, code: 0) }
            clearCall(call.uuid)
        }
        SipEngine.shared.closeSoundDevice()
    }

    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        guard let current = call, current.uuid == action.callUUID else {
            print("CallKit: answer with no live call")
            action.fail()
            return
        }
        print("CallKit: answer")
        WakeTimeline.shared.mark("accepted")
        call?.isAnswered = true
        if let id = current.id {
            answer(id, action: action)
        } else {
            call?.heldAnswer = action
        }
    }

    /// A timed-out action must not be fulfilled or failed afterwards.
    func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        print("CallKit: action timed out")
        if action === call?.heldAnswer { call?.heldAnswer = nil }
    }

    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        guard let current = call, current.uuid == action.callUUID else {
            action.fulfill()
            return
        }
        print("CallKit: end, answered \(current.isAnswered)")
        clearCall(current.uuid)
        if let id = current.id {
            SipEngine.shared.hangUp(id, code: current.isAnswered ? 0 : 603)
        } else {
            current.heldAnswer?.fail()
            decline(current.uuid, token: current.token)
        }
        action.fulfill()
    }

    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        print("CallKit: didActivate")
        WakeTimeline.shared.mark("didActivate")
        SipEngine.shared.openSoundDevice()
    }

    /// Does not mean the call ended: a cellular call can take the session mid-call.
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        print("CallKit: didDeactivate")
        SipEngine.shared.closeSoundDevice()
    }
}
