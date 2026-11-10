import Foundation
import UIKit

/// Runs work on main from the SIP thread, in order and without blocking it.
nonisolated func onMain(_ work: @escaping @MainActor () -> Void) {
    DispatchQueue.main.async { MainActor.assumeIsolated(work) }
}

/// Owns pjsip. Every pj_* call runs on one dedicated thread that polls for events,
/// because the main thread must never call into pjsip and callbacks must never block
/// on main.
nonisolated final class SipEngine: @unchecked Sendable {
    static let shared = SipEngine()

    private static let noAccount = pjsua_acc_id(-1)
    private static let noCall = pjsua_call_id(-1)
    private static let videoMediaIndex: UInt32 = 1
    private static let stunServer = "stun.pjsip.org"
    private static let retryIntervalSeconds: UInt32 = 30
    private static let callUUIDHeader = "X-PB-Call-UUID"

    private let lock = NSLock()
    private var inbox: [() -> Void] = []
    private var isStarted = false

    // Only touched on the SIP thread.
    private var accountId = SipEngine.noAccount
    private var account: SipAccount?
    private var isUnregistering = false
    /// Set while the account stays configured with its registration off, in the background.
    private var isPaused = false
    private var currentCall = SipEngine.noCall
    /// Per call, because a rejected second call has media of its own, which pjsip frees.
    private var videoTransports: [pjsua_call_id: UnsafeMutablePointer<pjmedia_transport>] = [:]
    private var videoKeepAlive: VideoKeepAlive?

    /// Starts the SIP thread. Calling it again does nothing.
    func start() {
        lock.lock()
        defer { lock.unlock() }
        guard !isStarted else { return }
        isStarted = true

        let thread = Thread { [self] in
            guard bootstrap() else { return }
            while true {
                drainInbox()
                _ = pjsua_handle_events(10)
                videoKeepAlive?.sendIfDue()
            }
        }
        thread.name = "sip"
        thread.stackSize = 1 << 20
        thread.start()
    }

    func unregister() {
        post { [self] in removeRegistration() }
    }

    /// Registers in the foreground, because the app may have been suspended past the
    /// registration's expiry. Changed details replace the account. Calls are left alone.
    func connect(_ newAccount: SipAccount, instanceId: String) {
        post { [self] in
            guard currentCall == Self.noCall else { return }
            isPaused = false
            guard accountId != Self.noAccount, !isUnregistering, account == newAccount else {
                addAccount(newAccount, instanceId: instanceId)
                return
            }
            publish(.registering)
            let status = pjsua_acc_set_registration(accountId, 1)
            if status != 0 {
                publish(.failed(RegistrationFailure(code: 0, reason: errorText(status), isRetrying: false)))
            }
        }
    }

    /// Registers for a push. A suspended app's sockets may be dead, so it restarts the
    /// transport, which also re-registers an account whose registration is off.
    func wake(_ newAccount: SipAccount, instanceId: String) {
        post { [self] in
            guard currentCall == Self.noCall else { return }
            isPaused = false
            guard accountId != Self.noAccount, account == newAccount else {
                addAccount(newAccount, instanceId: instanceId)
                return
            }
            publish(.registering)
            var parameters = pjsua_ip_change_param()
            pjsua_ip_change_param_default(&parameters)
            let status = pjsua_handle_ip_change(&parameters)
            if status != 0 {
                publish(.failed(RegistrationFailure(code: 0, reason: errorText(status), isRetrying: false)))
            }
        }
    }

    /// Un-REGISTERs for the background, keeping the account for the next push.
    func pause() {
        post { [self] in
            guard accountId != Self.noAccount, currentCall == Self.noCall, !isUnregistering else { return }
            isPaused = true
            _ = pjsua_acc_set_registration(accountId, 0)
        }
    }

    /// Sends 180 once CallKit has accepted the report.
    func ring(_ id: pjsua_call_id) {
        post { [self] in _ = answerCall(id, code: 180) }
    }

    func answer(_ id: pjsua_call_id, completion: @escaping @Sendable (Bool) -> Void) {
        post { [self] in completion(answerCall(id, code: 200) == 0) }
    }

    /// A code of 0 lets pjsua pick the right ending for the call's state.
    func hangUp(_ id: pjsua_call_id, code: UInt32) {
        post { [self] in
            logVideoStats(id)
            pjsua_call_hangup(id, code, nil, nil)
        }
    }

    /// Sends RFC 2833 digits and reports a failure reason, or nil on success.
    func sendDigits(_ id: pjsua_call_id, _ digits: String, completion: @escaping @Sendable (String?) -> Void) {
        post { [self] in
            let copy = strdup(digits)
            defer { free(copy) }
            var parameters = pjsua_call_send_dtmf_param()
            pjsua_call_send_dtmf_param_default(&parameters)
            parameters.digits = pj_str(copy)

            let status = pjsua_call_send_dtmf(id, &parameters)
            print("SipEngine: DTMF sent, status \(status)")
            switch status {
            case 0: completion(nil)
            case PJMEDIA_RTP_EREMNORFC2833: completion(String(localized: "Door code not sent: caller doesn't support DTMF"))
            default: completion(String(localized: "Door code not sent: \(errorText(status))"))
            }
        }
    }

    func openSoundDevice() {
        post { [self] in
            let status = pjsua_set_snd_dev(PJSUA_SND_DEFAULT_CAPTURE_DEV.rawValue, PJSUA_SND_DEFAULT_PLAYBACK_DEV.rawValue)
            if status != 0 { print("SipEngine: sound device failed: \(errorText(status))") }
        }
    }

    func closeSoundDevice() {
        post { _ = pjsua_set_no_snd_dev() }
    }

    private func post(_ job: @escaping () -> Void) {
        lock.lock()
        inbox.append(job)
        lock.unlock()
    }

    private func drainInbox() {
        lock.lock()
        let jobs = inbox
        inbox.removeAll()
        lock.unlock()
        jobs.forEach { $0() }
    }

    // MARK: SIP thread

    private func bootstrap() -> Bool {
        var status = pjsua_create()
        guard status == 0 else { return failStartup("pjsua_create", status) }

        let stun = strdup(Self.stunServer)
        defer { free(stun) }

        var config = pjsua_config()
        pjsua_config_default(&config)
        config.thread_cnt = 0
        config.stun_srv_cnt = 1
        config.stun_srv.0 = pj_str(stun)
        config.cb.on_reg_started2 = onRegistrationStarted
        config.cb.on_reg_state2 = onRegistrationState
        config.cb.on_incoming_call = onIncomingCall
        config.cb.on_call_state = onCallState
        config.cb.on_call_media_state = onCallMediaState
        config.cb.on_call_media_event = onCallMediaEvent
        config.cb.on_create_media_transport = onCreateMediaTransport

        var logging = pjsua_logging_config()
        pjsua_logging_config_default(&logging)
        logging.console_level = 4

        var media = pjsua_media_config()
        pjsua_media_config_default(&media)
        media.no_vad = 1

        status = pjsua_init(&config, &logging, &media)
        guard status == 0 else { return failStartup("pjsua_init", status) }

        // Port 0 binds an ephemeral local port. The account picks its transport
        // through `;transport=` on the registrar URI.
        var transport = pjsua_transport_config()
        pjsua_transport_config_default(&transport)
        status = pjsua_transport_create(PJSIP_TRANSPORT_UDP, &transport, nil)
        guard status == 0 else { return failStartup("UDP transport", status) }
        status = pjsua_transport_create(PJSIP_TRANSPORT_TCP, &transport, nil)
        guard status == 0 else { return failStartup("TCP transport", status) }

        status = pjsua_start()
        guard status == 0 else { return failStartup("pjsua_start", status) }

        // CallKit owns the audio session, so the device stays closed until `didActivate`.
        _ = pjsua_set_no_snd_dev()

        print("SipEngine: started pjsip \(String(cString: pj_get_version()))")
        onMain { WakeTimeline.shared.mark("pjsua started") }
        return true
    }

    private func failStartup(_ step: String, _ status: pj_status_t) -> Bool {
        publish(.failed(RegistrationFailure(
            code: 0,
            reason: "\(step) failed: \(errorText(status))",
            isRetrying: false
        )))
        return false
    }

    private func addAccount(_ newAccount: SipAccount, instanceId: String) {
        deleteAccount()
        publish(.registering)

        let uri = strdup("sip:\(newAccount.username)@\(newAccount.domain)")
        let registrar = strdup("sip:\(newAccount.registrar):\(newAccount.port);transport=\(newAccount.transport.lowercased())")
        let realm = strdup("*")
        let scheme = strdup("digest")
        let username = strdup(newAccount.username)
        let password = strdup(newAccount.password)
        let contactParameters = strdup(";+sip.instance=\"<urn:uuid:\(instanceId)>\"")
        defer { for string in [uri, registrar, realm, scheme, username, password, contactParameters] { free(string) } }

        var config = pjsua_acc_config()
        pjsua_acc_config_default(&config)
        config.id = pj_str(uri)
        config.reg_uri = pj_str(registrar)
        config.cred_count = 1
        config.cred_info.0.realm = pj_str(realm)
        config.cred_info.0.scheme = pj_str(scheme)
        config.cred_info.0.username = pj_str(username)
        config.cred_info.0.data_type = Int32(PJSIP_CRED_DATA_PLAIN_PASSWD.rawValue)
        config.cred_info.0.data = pj_str(password)
        config.reg_retry_interval = Self.retryIntervalSeconds
        // pjsua drops its own instance ID on UDP, so it goes in by hand. A relaunch then replaces
        // the old `location` row rather than leaving a ghost beside it.
        config.use_rfc5626 = 0
        config.reg_contact_params = pj_str(contactParameters)
        config.ice_cfg_use = PJSUA_ICE_CONFIG_USE_CUSTOM
        config.ice_cfg.enable_ice = 1
        config.vid_in_auto_show = 1
        config.vid_out_auto_transmit = 0

        var id = Self.noAccount
        let status = pjsua_acc_add(&config, 1, &id)
        guard status == 0 else {
            let reason = errorText(status)
            onMain { WakeTimeline.shared.mark("account not added: \(reason)") }
            publish(.failed(RegistrationFailure(code: 0, reason: reason, isRetrying: false)))
            return
        }
        accountId = id
        account = newAccount
    }

    /// Sends an un-REGISTER when the server holds a registration, and leaves deleting the
    /// account to the callback. `pjsua_acc_del` alone would fire no `on_reg_state2`.
    private func removeRegistration() {
        guard accountId != Self.noAccount else {
            publish(.notRegistered)
            return
        }
        var info = pjsua_acc_info()
        let isHeld = pjsua_acc_get_info(accountId, &info) == 0 && info.status.rawValue / 100 == 2 && info.expires > 0
        if isHeld, pjsua_acc_set_registration(accountId, 0) == 0 {
            isUnregistering = true
        } else {
            deleteAccount()
            publish(.notRegistered)
        }
    }

    private func deleteAccount() {
        guard accountId != Self.noAccount else { return }
        pjsua_acc_del(accountId)
        accountId = Self.noAccount
        account = nil
        isUnregistering = false
        isPaused = false
    }

    /// A REGISTER with no answer only reports its result after about 32 s, which is after the wake
    /// has ended, so the timeline also needs to show that it went out.
    fileprivate func handleRegistrationStarted(account: pjsua_acc_id, info: pjsua_reg_info) {
        guard account == accountId || accountId == Self.noAccount else { return }
        let label = info.renew != 0 ? "REGISTER" : "un-REGISTER"
        onMain { WakeTimeline.shared.mark("\(label) sent") }
    }

    fileprivate func handleRegistrationState(account: pjsua_acc_id, info: pjsua_reg_info) {
        guard account == accountId || accountId == Self.noAccount, let result = info.cbparam?.pointee else { return }
        let reason = text(result.reason)
        print("SipEngine: registration \(result.code) \(reason), expiry \(result.expiration), status \(result.status)")
        let label = info.renew != 0 ? "REGISTER" : "un-REGISTER"
        let outcome = result.code == 0 ? "failed: \(errorText(result.status))" : "\(result.code) \(reason)"
        let expiry = result.expiration
        onMain { WakeTimeline.shared.mark("\(label) \(outcome), expiry \(expiry)") }

        if isUnregistering {
            // Deleting inside a pjsua callback is unsafe, so it waits for the next loop.
            post { [self] in
                deleteAccount()
                publish(.notRegistered)
            }
            return
        }

        if isPaused { return }

        if result.status == 0, result.code / 100 == 2 {
            onMain { CallManager.shared.wakeRegistered() }
            publish(.registered(expirySeconds: Int(result.expiration)))
        } else {
            publish(.failed(RegistrationFailure(
                code: Int(result.code),
                reason: result.code == 0 ? errorText(result.status) : reason,
                isRetrying: Self.pjsuaRetries(code: Int(result.code))
            )))
        }
    }

    fileprivate func handleIncomingCall(_ id: pjsua_call_id, data: UnsafeMutablePointer<pjsip_rx_data>?) {
        guard currentCall == Self.noCall else {
            print("SipEngine: busy, rejecting call \(id)")
            pjsua_call_answer(id, 486, nil, nil)
            return
        }
        currentCall = id

        var info = pjsua_call_info()
        pjsua_call_get_info(id, &info)
        let caller = Self.callerName(text(info.remote_info))
        let callUUID = callUUID(data)
        print("SipEngine: incoming call \(id) from \(caller), UUID \(callUUID?.uuidString ?? "none")")
        onMain { CallManager.shared.reportIncoming(id: id, caller: caller, callUUID: callUUID) }
    }

    /// Read here, because the message doesn't outlive the callback.
    private func callUUID(_ data: UnsafeMutablePointer<pjsip_rx_data>?) -> UUID? {
        guard let message = data?.pointee.msg_info.msg else { return nil }
        let headerName = strdup(Self.callUUIDHeader)
        defer { free(headerName) }
        var name = pj_str(headerName)
        guard let header = pjsip_msg_find_hdr_by_name(message, &name, nil) else { return nil }
        return UUID(uuidString: text(header.assumingMemoryBound(to: pjsip_generic_string_hdr.self).pointee.hvalue))
    }

    fileprivate func handleCallState(_ id: pjsua_call_id) {
        var info = pjsua_call_info()
        guard pjsua_call_get_info(id, &info) == 0 else { return }
        print("SipEngine: call \(id) \(text(info.state_text)), last status \(info.last_status.rawValue)")

        if info.state == PJSIP_INV_STATE_CONFIRMED {
            onMain { CallManager.shared.callConnected(id: id) }
        } else if info.state == PJSIP_INV_STATE_DISCONNECTED {
            let lastStatus = Int(info.last_status.rawValue)
            // Now, not in the job below: the keep-alive runs before the next inbox drain, and
            // the transport is about to be freed.
            videoTransports[id] = nil
            if currentCall == id { videoKeepAlive = nil }
            // pjsip's auto-close leaves the next call able to open the device early, so this
            // re-arms it. It has to finish before CallKit hears the call ended.
            post { [self] in
                _ = pjsua_set_no_snd_dev()
                if currentCall == id { currentCall = Self.noCall }
                onMain { CallManager.shared.callEnded(id: id, lastStatus: lastStatus) }
            }
        }
    }

    /// Answers with video receive-only, so the camera is never negotiated. The 180 and the
    /// 200 must carry the same setting, because pjsua fixes it at the first answer.
    private func answerCall(_ id: pjsua_call_id, code: UInt32) -> pj_status_t {
        var setting = pjsua_call_setting()
        pjsua_call_setting_default(&setting)
        setting.flag |= PJSUA_CALL_SET_MEDIA_DIR.rawValue
        setting.media_dir.1 = PJMEDIA_DIR_DECODING
        return pjsua_call_answer2(id, &setting, code, nil, nil)
    }

    fileprivate func handleCallMedia(_ id: pjsua_call_id) {
        let port = pjsua_call_get_conf_port(id)
        if port >= 0 {
            pjsua_conf_connect(port, 0)
            pjsua_conf_connect(0, port)
            onMain { CallManager.shared.audioActive(id: id) }
        }
        publishVideo(id)
        startVideoKeepAlive(id)
    }

    fileprivate func handleCreateMediaTransport(_ id: pjsua_call_id, mediaIndex: UInt32, transport: UnsafeMutablePointer<pjmedia_transport>) {
        if mediaIndex == Self.videoMediaIndex { videoTransports[id] = transport }
    }

    /// A receive-only stream sends one empty RTP packet at start and never again, because
    /// pjsip's keep-alive only runs when frames are encoded. That leaves the NAT shut and
    /// the server unable to learn where to send video.
    private func startVideoKeepAlive(_ id: pjsua_call_id) {
        guard let videoTransport = videoTransports[id], decodingWindow(id) != nil else { return }
        var info = pjsua_stream_info()
        guard pjsua_call_get_stream_info(id, Self.videoMediaIndex, &info) == 0 else { return }
        let payloadType = UInt8(truncatingIfNeeded: info.info.vid.tx_pt)
        if videoKeepAlive == nil {
            videoKeepAlive = VideoKeepAlive(transport: videoTransport, payloadType: payloadType)
        }
        videoKeepAlive?.restartBurst()
    }

    fileprivate func handleCallMediaEvent(_ id: pjsua_call_id, event: pjmedia_event) {
        guard event.type == PJMEDIA_EVENT_FMT_CHANGED else { return }
        let size = event.data.fmt_changed.new_fmt.det.vid.size
        print("SipEngine: video format \(size.w)x\(size.h)")
        onMain { SipStore.shared.setVideoSize(CGSize(width: Int(size.w), height: Int(size.h))) }
        publishVideo(id)
    }

    /// Runs on every media update, because pjsua can replace the window mid-call. The view
    /// is taken here so it stays alive during the hop to main.
    private func publishVideo(_ id: pjsua_call_id) {
        guard let window = decodingWindow(id) else { return }
        var info = pjsua_vid_win_info()
        guard pjsua_vid_win_get_info(window, &info) == 0, let pointer = info.hwnd.info.ios.window else { return }
        let view = Unmanaged<UIView>.fromOpaque(pointer).takeUnretainedValue()
        let size = CGSize(width: Int(info.size.w), height: Int(info.size.h))
        onMain { SipStore.shared.setRemoteVideo(view, initialSize: size) }
    }

    /// The window id is checked first, because a bad id asserts rather than returning an error.
    private func decodingWindow(_ id: pjsua_call_id) -> pjsua_vid_win_id? {
        var info = pjsua_call_info()
        guard pjsua_call_get_info(id, &info) == 0 else { return nil }
        let count = Int(info.media_cnt)
        return withUnsafeBytes(of: info.media) { bytes in
            bytes.bindMemory(to: pjsua_call_media_info.self).prefix(count).first {
                $0.type == PJMEDIA_TYPE_VIDEO
                    && $0.dir.rawValue & PJMEDIA_DIR_DECODING.rawValue != 0
                    && $0.stream.vid.win_in >= 0
            }?.stream.vid.win_in
        }
    }

    /// Shows at hang-up that video came in and nothing went out.
    private func logVideoStats(_ id: pjsua_call_id) {
        var info = pjsua_call_info()
        guard pjsua_call_get_info(id, &info) == 0 else { return }
        let count = Int(info.media_cnt)
        let index = withUnsafeBytes(of: info.media) { bytes in
            bytes.bindMemory(to: pjsua_call_media_info.self).prefix(count).first { $0.type == PJMEDIA_TYPE_VIDEO }?.index
        }
        var stat = pjsua_stream_stat()
        guard let index, pjsua_call_get_stream_stat(id, index, &stat) == 0 else { return }
        print("SipEngine: video packets received \(stat.rtcp.rx.pkt), sent \(stat.rtcp.tx.pkt)")
    }

    /// Takes `"Name" <sip:user@host>` or `<sip:user@host>` to a name or the user part.
    private static func callerName(_ remote: String) -> String {
        let parts = remote.split(separator: "\"", omittingEmptySubsequences: false)
        if parts.count >= 3, !parts[1].isEmpty { return String(parts[1]) }
        guard let start = remote.range(of: "sip:")?.upperBound else { return remote }
        return String(remote[start...].prefix { $0 != "@" && $0 != ">" && $0 != ";" })
    }

    /// Mirrors the codes `pjsua_acc.c` retries after `reg_retry_interval`.
    private static func pjsuaRetries(code: Int) -> Bool {
        [408, 480, 500, 502, 503, 504].contains(code) || code / 100 == 6
    }

    private func publish(_ state: RegistrationState) {
        onMain { SipStore.shared.apply(state) }
    }

    private func text(_ value: pj_str_t) -> String {
        guard let pointer = value.ptr, value.slen > 0 else { return "" }
        return String(decoding: UnsafeRawBufferPointer(start: pointer, count: Int(value.slen)), as: UTF8.self)
    }

    private func errorText(_ status: pj_status_t) -> String {
        var buffer = [CChar](repeating: 0, count: 160)
        return text(pj_strerror(status, &buffer, buffer.count))
    }
}

/// Sends header-only RTP from the video socket. Carries no media.
private nonisolated final class VideoKeepAlive {
    private static let burstCount = 8
    private static let burstInterval: TimeInterval = 0.04
    private static let steadyInterval: TimeInterval = 5

    private let transport: UnsafeMutablePointer<pjmedia_transport>
    private let payloadType: UInt8
    private let ssrc = UInt32.random(in: 1...UInt32.max)
    private var sequence = UInt16.random(in: 0...UInt16.max)
    private var timestamp = UInt32.random(in: 0...UInt32.max)
    private var burstRemaining = 0
    private var nextSend = Date.distantPast

    init(transport: UnsafeMutablePointer<pjmedia_transport>, payloadType: UInt8) {
        self.transport = transport
        self.payloadType = payloadType
    }

    func restartBurst() {
        burstRemaining = Self.burstCount
        nextSend = .distantPast
    }

    func sendIfDue() {
        let now = Date()
        guard now >= nextSend else { return }
        send()
        if burstRemaining > 0 { burstRemaining -= 1 }
        nextSend = now.addingTimeInterval(burstRemaining > 0 ? Self.burstInterval : Self.steadyInterval)
    }

    private func send() {
        sequence &+= 1
        timestamp &+= 3000
        var packet: [UInt8] = [0x80, payloadType & 0x7F]
        packet += withUnsafeBytes(of: sequence.bigEndian, Array.init)
        packet += withUnsafeBytes(of: timestamp.bigEndian, Array.init)
        packet += withUnsafeBytes(of: ssrc.bigEndian, Array.init)
        let status = packet.withUnsafeBytes { bytes in
            transport.pointee.op.pointee.send_rtp(transport, bytes.baseAddress, bytes.count)
        }
        if status != 0 { print("SipEngine: video keep-alive failed (\(status))") }
    }
}

private nonisolated func onRegistrationStarted(_ account: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    guard let info else { return }
    SipEngine.shared.handleRegistrationStarted(account: account, info: info.pointee)
}

private nonisolated func onRegistrationState(_ account: pjsua_acc_id, _ info: UnsafeMutablePointer<pjsua_reg_info>?) {
    guard let info else { return }
    SipEngine.shared.handleRegistrationState(account: account, info: info.pointee)
}

private nonisolated func onIncomingCall(_ account: pjsua_acc_id, _ id: pjsua_call_id, _ data: UnsafeMutablePointer<pjsip_rx_data>?) {
    SipEngine.shared.handleIncomingCall(id, data: data)
}

private nonisolated func onCallState(_ id: pjsua_call_id, _ event: UnsafeMutablePointer<pjsip_event>?) {
    SipEngine.shared.handleCallState(id)
}

private nonisolated func onCallMediaState(_ id: pjsua_call_id) {
    SipEngine.shared.handleCallMedia(id)
}

private nonisolated func onCallMediaEvent(_ id: pjsua_call_id, _ index: UInt32, _ event: UnsafeMutablePointer<pjmedia_event>?) {
    guard let event else { return }
    SipEngine.shared.handleCallMediaEvent(id, event: event.pointee)
}

private nonisolated func onCreateMediaTransport(
    _ id: pjsua_call_id,
    _ mediaIndex: UInt32,
    _ transport: UnsafeMutablePointer<pjmedia_transport>?,
    _ flags: UInt32
) -> UnsafeMutablePointer<pjmedia_transport>? {
    if let transport { SipEngine.shared.handleCreateMediaTransport(id, mediaIndex: mediaIndex, transport: transport) }
    return transport
}
