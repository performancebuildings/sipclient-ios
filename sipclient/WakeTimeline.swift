import Foundation

/// The last wake's timing, kept on the phone because a wake test runs without Xcode attached.
/// Home shows it to users with `KeycloakConfig.debugRole`.
@Observable final class WakeTimeline {
    static let shared = WakeTimeline()

    private static let key = "wake.timeline"
    private static let coldLaunchSeconds = 5.0

    private(set) var lines = UserDefaults.standard.stringArray(forKey: WakeTimeline.key) ?? []
    private var startedAt: Date?

    /// Starts a new timeline at the push. `sentAt` comes from the payload, on the sender's clock.
    func begin(launchedAt: Date?, sentAt: Date?) {
        let now = Date()
        startedAt = now
        lines = []
        add(now.formatted(date: .abbreviated, time: .standard))
        // A push that launches the app reaches it within moments of launch.
        if let launchedAt, now.timeIntervalSince(launchedAt) < Self.coldLaunchSeconds {
            add("cold: launched \(Self.seconds(now.timeIntervalSince(launchedAt))) before the push")
        } else {
            add("warm: the app was already running")
        }
        if let sentAt { add("push arrived \(Self.seconds(now.timeIntervalSince(sentAt))) after sending") }
        mark("push")
    }

    func mark(_ label: String) {
        guard let startedAt else { return }
        add("+\(Self.seconds(Date().timeIntervalSince(startedAt))) \(label)")
    }

    private func add(_ line: String) {
        print("Wake: \(line)")
        lines.append(line)
        UserDefaults.standard.set(lines, forKey: Self.key)
    }

    private static func seconds(_ interval: TimeInterval) -> String {
        String(format: "%.2f s", interval)
    }
}
