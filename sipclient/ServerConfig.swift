import Foundation

/// The server the app talks to. The host comes from `PB_SERVER_HOST` in
/// `Config/App.xcconfig` (overridden by `Config/Private.xcconfig`), through the
/// `PBServerHost` key in Info.plist.
nonisolated enum ServerConfig {
    static let host: String = {
        guard let host = Bundle.main.object(forInfoDictionaryKey: "PBServerHost") as? String,
              !host.isEmpty, !host.hasPrefix("$(") else {
            fatalError("PBServerHost is missing from Info.plist; check Config/App.xcconfig")
        }
        return host
    }()

    /// `https://<host>/<path>`. `path` ends in a slash so that `appending(path:)` adds below it.
    static func url(_ path: String) -> URL {
        guard let url = URL(string: "https://\(host)/\(path)") else {
            fatalError("PB_SERVER_HOST \"\(host)\" doesn't make a valid URL")
        }
        return url
    }
}
