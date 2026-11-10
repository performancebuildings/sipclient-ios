import Foundation
import UIKit

/// What a push carries. `callToken` is missing from a hand-sent test push.
struct WakePush {
    let uuid: UUID
    let caller: String
    /// On the server's clock.
    let sentAt: Date?
    let callToken: String?
}

/// The wake's status route on the management server. The token comes from the push, so this
/// works on a locked phone and never touches Keycloak.
enum WakeAPI {
    nonisolated enum Report: String, Encodable, Sendable {
        case waiting, declined
    }

    nonisolated enum Answer: String, Decodable, Sendable {
        case alive, over
    }

    enum Failure: Error {
        case status(Int)
    }

    private nonisolated struct Body: Encodable, Sendable {
        let status: Report
    }

    private nonisolated struct Reply: Decodable, Sendable {
        let call: Answer
    }

    static let pollSeconds = 1.0

    private static let baseURL = ServerConfig.url("wake/v1/calls/")
    private static let timeoutSeconds = 3.0
    /// Past this the server has long since stopped waiting for a decline.
    private static let declineLimitSeconds = 15.0
    private static let session = URLSession(configuration: .ephemeral)

    /// A 401 is a wrong token, not an ended call, so it throws rather than answering `over`.
    static func send(_ report: Report, uuid: UUID, token: String) async throws -> Answer {
        let path = "\(uuid.uuidString.lowercased())/status"
        var request = URLRequest(url: baseURL.appending(path: path))
        request.httpMethod = "POST"
        request.timeoutInterval = timeoutSeconds
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(Body(status: report))

        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure.status(status) }
        return try JSONDecoder().decode(Reply.self, from: data).call
    }

    /// Repeats until the server has heard. The background task starts before this returns,
    /// because iOS suspends the app straight after a refused report.
    static func decline(uuid: UUID, token: String) {
        let application = UIApplication.shared
        let work = Task {
            let limit = Date().addingTimeInterval(declineLimitSeconds)
            while !Task.isCancelled, Date() < limit {
                do {
                    _ = try await send(.declined, uuid: uuid, token: token)
                    WakeTimeline.shared.mark("decline heard")
                    return
                } catch {
                    print("Wake: decline not heard: \(error)")
                }
                try? await Task.sleep(for: .seconds(pollSeconds))
            }
        }
        let backgroundTask = application.beginBackgroundTask { work.cancel() }
        Task {
            await work.value
            application.endBackgroundTask(backgroundTask)
        }
    }
}
