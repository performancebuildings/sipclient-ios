//
//  AcknowledgementsView.swift
//  sipclient
//

import SwiftUI

/// The open source software in the app and its licences, whose texts ship in Licenses/.
///
/// Lists what is linked into the build: PJSIP and the third-party code its build compiles in
/// (scripts/build-pjsip-ios.sh), plus AppAuth. G.722.1 is left out because the build has
/// PJMEDIA_HAS_G7221_CODEC off. Update this list when a dependency or the PJSIP config changes.
struct AcknowledgementsView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(Acknowledgement.all) { item in
                        NavigationLink(value: item) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(verbatim: item.name)
                                Text(verbatim: item.license)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                } footer: {
                    Text("This app uses the open source software listed here. Tap an entry to read its licence.")
                }
            }
            .navigationTitle("Acknowledgements")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: Acknowledgement.self) { LicenseTextView(item: $0) }
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

/// Licence texts stay in English: they're legal texts, and only the original is binding.
private struct LicenseTextView: View {
    let item: Acknowledgement

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if let url = item.url {
                    Link(destination: url) { Text(verbatim: url.absoluteString) }
                        .font(.footnote)
                }
                Text(verbatim: item.text)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle(Text(verbatim: item.name))
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct Acknowledgement: Identifiable, Hashable {
    let name: String
    let license: String
    let url: URL?
    /// Resource name of the licence text in Licenses/, without the .txt extension.
    let file: String

    var id: String { file }

    var text: String {
        guard let url = Bundle.main.url(forResource: file, withExtension: "txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return "" }
        return text
    }

    static let all: [Acknowledgement] = [
        .init(name: "PJSIP 2.17", license: "GNU GPL v2 or later",
              url: URL(string: "https://www.pjsip.org"), file: "license-pjsip"),
        .init(name: "AppAuth for iOS", license: "Apache License 2.0",
              url: URL(string: "https://github.com/openid/AppAuth-iOS"), file: "license-appauth"),
        .init(name: "Speex", license: "BSD 3-Clause",
              url: URL(string: "https://www.speex.org"), file: "license-speex"),
        .init(name: "GSM 06.10", license: "TU Berlin licence",
              url: URL(string: "https://www.quut.com/gsm/"), file: "license-gsm"),
        .init(name: "iLBC", license: "BSD 3-Clause",
              url: nil, file: "license-ilbc"),
        .init(name: "WebRTC", license: "BSD 3-Clause, with third-party notices",
              url: URL(string: "https://webrtc.org"), file: "license-webrtc"),
        .init(name: "libyuv", license: "BSD 3-Clause",
              url: URL(string: "https://chromium.googlesource.com/libyuv/libyuv/"), file: "license-libyuv"),
    ]
}

#Preview {
    AcknowledgementsView()
}
