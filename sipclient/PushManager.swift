import BackgroundTasks
import PushKit
import UIKit

/// Runs the start-up a push needs, because a background launch may never build a view.
final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        PushManager.shared.launchedAt = Date()
        CallManager.shared.prepareAudioSession()
        PushManager.shared.start()
        SipEngine.shared.start()
        BGTaskScheduler.shared.register(forTaskWithIdentifier: AppSession.refreshTaskIdentifier, using: .main) { task in
            MainActor.assumeIsolated { AppSession.shared.handleRefreshTask(task) }
        }
        return true
    }
}

/// Receives VoIP pushes. The delegate must report each call to CallKit before it returns,
/// or iOS kills the app and, after repeated misses, stops delivering VoIP pushes to it.
/// So nothing here may be async.
@Observable final class PushManager: NSObject, PKPushRegistryDelegate {
    static let shared = PushManager()

    /// Set only when the push is the first since launch, so a warm wake shows no launch time.
    @ObservationIgnored var launchedAt: Date?
    private(set) var token: String?

    @ObservationIgnored private let registry = PKPushRegistry(queue: .main)

    func start() {
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
    }

    func pushRegistry(_ registry: PKPushRegistry, didUpdate credentials: PKPushCredentials, for type: PKPushType) {
        token = credentials.token.map { String(format: "%02x", $0) }.joined()
        print("Push: token \(token ?? "")")
        AppSession.shared.pushTokenChanged()
    }

    func pushRegistry(_ registry: PKPushRegistry, didInvalidatePushTokenFor type: PKPushType) {
        token = nil
    }

    func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        let values = payload.dictionaryPayload
        let push = WakePush(
            uuid: (values["uuid"] as? String).flatMap(UUID.init(uuidString:)) ?? UUID(),
            caller: values["caller"] as? String ?? String(localized: "Door"),
            sentAt: (values["sentAt"] as? Double).map { Date(timeIntervalSince1970: $0 / 1000) },
            callToken: values["callToken"] as? String
        )

        // A push during a call would otherwise replace the running call's timeline.
        if !CallManager.shared.isBusy {
            WakeTimeline.shared.begin(launchedAt: launchedAt, sentAt: push.sentAt)
            launchedAt = nil
        }
        CallManager.shared.reportPush(push, completion: completion)
    }
}
