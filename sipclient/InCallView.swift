import SwiftUI
import UIKit

/// The answered call: remote video filling the screen, with the controls over it.
struct InCallView: View {
    private static let sentDisplayTime = Duration.seconds(2)

    private let store = SipStore.shared
    private let isDebugUser = AuthStore.shared.isDebugUser
    @State private var isShowingSent = false
    @State private var pressedDigits = ""
    @State private var doorFailure: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            RemoteVideoView(video: store.remoteVideo, size: store.videoSize)
                .ignoresSafeArea()
            if store.remoteVideo == nil {
                Text("Waiting for video…").foregroundStyle(.white)
            }
            VStack {
                Text(store.call?.caller ?? "")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .shadow(radius: 2)
                Spacer()
                if let doorFailure {
                    Text(doorFailure)
                        .font(.footnote)
                        .foregroundStyle(.white)
                        .padding(8)
                        .background(.red, in: RoundedRectangle(cornerRadius: 8))
                }
                if isDebugUser {
                    Text(verbatim: pressedDigits)
                        .font(.title2.monospaced())
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                    Keypad(isEnabled: isAudioActive, press: send)
                    endCallButton
                } else {
                    HStack(spacing: 16) {
                        Button(action: openDoor) {
                            Text(isShowingSent ? "Sent" : "Open door")
                                .font(.title3.bold())
                                .frame(maxWidth: .infinity, minHeight: 72)
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(!isAudioActive || isShowingSent)

                        endCallButton
                    }
                }
            }
            .padding()
        }
    }

    private var isAudioActive: Bool { store.call?.isAudioActive == true }

    private var endCallButton: some View {
        Button {
            CallManager.shared.endCall()
        } label: {
            Image(systemName: "phone.down.fill")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 72, height: 72)
                .background(.red, in: Circle())
        }
        .accessibilityLabel("End call")
    }

    private func send(_ digit: String) {
        pressedDigits += digit
        doorFailure = nil
        CallManager.shared.sendDigits(digit) { doorFailure = $0 }
    }

    private func openDoor() {
        // Disabled before the send returns, so a double-tap cannot queue two digits.
        isShowingSent = true
        doorFailure = nil
        CallManager.shared.openDoor { failure in
            doorFailure = failure
            guard failure == nil else {
                isShowingSent = false
                return
            }
            Task {
                try? await Task.sleep(for: Self.sentDisplayTime)
                isShowingSent = false
            }
        }
    }
}

/// A phone keypad for users with the debug role. Each press sends its digit at once.
private struct Keypad: View {
    private static let rows = [["1", "2", "3"], ["4", "5", "6"], ["7", "8", "9"], ["*", "0", "#"]]

    let isEnabled: Bool
    let press: (String) -> Void

    var body: some View {
        Grid(horizontalSpacing: 16, verticalSpacing: 12) {
            ForEach(Self.rows, id: \.self) { row in
                GridRow {
                    ForEach(row, id: \.self) { digit in
                        Button {
                            press(digit)
                        } label: {
                            Text(verbatim: digit)
                                .font(.title)
                                .foregroundStyle(.white)
                                .frame(width: 64, height: 64)
                                .background(.white.opacity(0.25), in: Circle())
                        }
                    }
                }
            }
        }
        .disabled(!isEnabled)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

private struct RemoteVideoView: UIViewRepresentable {
    let video: UIView?
    let size: CGSize

    func makeUIView(context: Context) -> VideoHost { VideoHost() }

    func updateUIView(_ host: VideoHost, context: Context) {
        host.show(video, size: size)
    }
}

/// Sizes pjsip's view to the video's aspect, because the Metal renderer stretches to fill
/// whatever frame it gets and `contentMode` has no effect on it.
private final class VideoHost: UIView {
    private var video: UIView?
    private var videoSize = CGSize.zero

    func show(_ newVideo: UIView?, size: CGSize) {
        if newVideo !== video {
            if video?.superview === self { video?.removeFromSuperview() }
            video = newVideo
            if let newVideo { addSubview(newVideo) }
        }
        videoSize = size
        setNeedsLayout()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        guard let video else { return }
        guard videoSize.width > 0, videoSize.height > 0 else {
            video.frame = bounds
            return
        }
        let scale = min(bounds.width / videoSize.width, bounds.height / videoSize.height)
        let fitted = CGSize(width: videoSize.width * scale, height: videoSize.height * scale)
        video.frame = CGRect(
            x: (bounds.width - fitted.width) / 2,
            y: (bounds.height - fitted.height) / 2,
            width: fitted.width,
            height: fitted.height
        )
    }
}
