import Foundation

/// This phone's identity on the server. `id` survives logout.
enum Device {
    /// Only read once the Keychain is readable, or it would replace the stored ID.
    static var id: String {
        if let data = Keychain.data(.deviceId) { return String(decoding: data, as: UTF8.self) }
        let id = UUID().uuidString.lowercased()
        Keychain.set(Data(id.utf8), for: .deviceId)
        return id
    }

    /// From the embedded profile, because `#if DEBUG` is wrong for a Release build run from
    /// Xcode. App Store builds carry no profile, and those use production.
    static let apnsEnvironment: String = profileEntitlement == "development" ? "sandbox" : "production"

    private static var profileEntitlement: String? {
        guard let url = Bundle.main.url(forResource: "embedded", withExtension: "mobileprovision"),
              let file = try? Data(contentsOf: url),
              let start = file.range(of: Data("<?xml".utf8)),
              let end = file.range(of: Data("</plist>".utf8)),
              let profile = try? PropertyListSerialization.propertyList(
                from: file[start.lowerBound..<end.upperBound], format: nil
              ) as? [String: Any],
              let entitlements = profile["Entitlements"] as? [String: Any] else { return nil }
        return entitlements["aps-environment"] as? String
    }
}
