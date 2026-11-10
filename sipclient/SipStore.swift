import Foundation
import Observation
import UIKit

nonisolated struct RegistrationFailure: Equatable, Sendable {
    let code: Int
    let reason: String
    let isRetrying: Bool

    var isAuthFailure: Bool { [401, 403, 407].contains(code) }

    /// One plain line for the two likely causes.
    var hint: String? {
        if code == 403 { return String(localized: "An admin may have changed this extension. If not, too many contacts may be registered; try again in 5 minutes.") }
        if isAuthFailure { return String(localized: "An admin may have changed this extension.") }
        if [0, 408, 502, 503].contains(code) { return String(localized: "Server unreachable. Check the network.") }
        return nil
    }
}

nonisolated enum RegistrationState: Equatable, Sendable {
    case notRegistered
    case registering
    case registered(expirySeconds: Int)
    case failed(RegistrationFailure)
}

nonisolated struct CallDisplay: Equatable, Sendable {
    let caller: String
    var isConnected: Bool
    var isAudioActive = false
}

/// Main-thread copy of what the SIP thread reports. Holds no pj_* calls.
@Observable final class SipStore {
    static let shared = SipStore()

    private(set) var state = RegistrationState.notRegistered
    private(set) var call: CallDisplay?
    private(set) var remoteVideo: UIView?
    private(set) var videoSize = CGSize.zero

    func setCall(_ newCall: CallDisplay?) {
        call = newCall
        if newCall == nil {
            remoteVideo = nil
            videoSize = .zero
        }
    }

    /// `initialSize` comes from the SDP, so it only stands in until the first decoded format.
    func setRemoteVideo(_ view: UIView, initialSize: CGSize) {
        remoteVideo = view
        if videoSize == .zero { videoSize = initialSize }
    }

    func setVideoSize(_ size: CGSize) {
        videoSize = size
    }

    func markCallConnected() {
        call?.isConnected = true
    }

    func markAudioActive() {
        call?.isAudioActive = true
    }

    func apply(_ newState: RegistrationState) {
        state = newState
        if case .failed(let failure) = newState, failure.isAuthFailure {
            AppSession.shared.sipLoginRefused()
        }
    }
}
