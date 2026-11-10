//
//  ContentView.swift
//  sipclient
//
//  Created by Michael on 05.11.2026.
//

import SwiftUI

struct ContentView: View {
    /// True until the first foreground, and again after each trip to the background.
    @State private var isForegroundDue = true
    @Environment(\.scenePhase) private var scenePhase

    private let session = AppSession.shared
    private let store = SipStore.shared

    var body: some View {
        // Home stays underneath the call, so its state survives the call.
        ZStack {
            VStack(spacing: 0) {
                LogoView()
                Group {
                    switch session.screen {
                    case .login: LoginView()
                    case .loading: ProgressView()
                    case .unreachable: UnreachableView()
                    case .notProvisioned: NotProvisionedView()
                    case .home: HomeView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(Color(.systemGroupedBackground))
            if store.call?.isConnected == true {
                InCallView()
            }
        }
        .onOpenURL { session.openInvite($0) }
        .alert(item: Bindable(session).invitePrompt) { prompt in
            switch prompt {
            case .invalid:
                Alert(title: Text("This invite link isn't valid"))
            case .unreachable:
                Alert(title: Text("Can't reach the server"), message: Text("Try the invite link again later."))
            case .confirmSwitch(let from, let to):
                Alert(
                    title: Text("Switch to \(to.displayName)?"),
                    message: Text("You'll be logged out of \(from.displayName) and stop receiving its door calls on this phone."),
                    primaryButton: .destructive(Text("Switch")) { session.switchTenant(to: to) },
                    secondaryButton: .cancel()
                )
            }
        }
        .onChange(of: scenePhase, initial: true) { oldPhase, phase in
            if phase == .active, isForegroundDue {
                isForegroundDue = false
                session.enterForeground()
            } else if phase == .background, oldPhase != .background {
                isForegroundDue = true
                CallManager.shared.unregisterIfIdle()
                session.enterBackground()
            }
        }
    }
}

/// The logo's dark text needs a light ground, so it keeps its white card in dark mode.
private struct LogoView: View {
    var body: some View {
        Image("PBLogo")
            .resizable()
            .scaledToFit()
            .frame(maxWidth: 240)
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.white, in: RoundedRectangle(cornerRadius: 10))
            .padding(.top, 8)
            .accessibilityLabel(Text(verbatim: "Performance Buildings"))
    }
}

private struct LoginView: View {
    private let session = AppSession.shared

    var body: some View {
        VStack(spacing: 16) {
            switch session.tenants {
            case .loading:
                ProgressView()
            case .failed:
                Text("Can't reach the server")
                Button("Try again") { Task { await session.loadTenants() } }
                    .buttonStyle(.borderedProminent)
            case .loaded(let tenants) where tenants.isEmpty:
                Text("There's nothing to log in to here. Open the invite link from your administrator.")
            case .loaded(let tenants) where tenants.count == 1:
                Button("Log in to \(tenants[0].displayName)") { session.login(to: tenants[0]) }
                    .buttonStyle(.borderedProminent)
                    .disabled(session.isLoggingIn)
            case .loaded(let tenants):
                Text("Log in to")
                ForEach(tenants) { tenant in
                    Button(tenant.displayName) { session.login(to: tenant) }
                        .buttonStyle(.bordered)
                        .frame(maxWidth: 320)
                        .disabled(session.isLoggingIn)
                }
            }
            if let name = session.rejectedTenantName {
                Text("\(name) didn't accept your login. Ask your administrator.")
                    .font(.footnote).foregroundStyle(.red)
            }
            if let error = session.loginError {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
            if session.isDeleteOwed {
                Text("This phone may still receive calls. Connect to the internet and log in again to fix this.")
                    .font(.footnote)
            }
            AcknowledgementsButton()
                .font(.footnote)
                .padding(.top, 24)
        }
        .multilineTextAlignment(.center)
        .padding()
        .task { await session.loadTenants() }
    }
}

private struct UnreachableView: View {
    private let session = AppSession.shared

    var body: some View {
        VStack(spacing: 16) {
            Text("Can't reach the server")
            if let reason = session.lookupFailure {
                Text(reason).font(.footnote).foregroundStyle(.secondary)
            }
            Button("Try again") { session.checkAgain() }
                .buttonStyle(.borderedProminent)
            LogoutButton()
        }
        .padding()
    }
}

private struct NotProvisionedView: View {
    private let session = AppSession.shared

    var body: some View {
        VStack(spacing: 16) {
            Text("Your account isn't set up for door calls yet. Ask an admin to provision it.")
                .multilineTextAlignment(.center)
            Button("Check again") { session.checkAgain() }
                .buttonStyle(.borderedProminent)
            LogoutButton()
        }
        .padding()
    }
}

private struct HomeView: View {
    private let session = AppSession.shared
    private let store = SipStore.shared

    var body: some View {
        Form {
            if let link = session.link {
                let showsExtension = AuthStore.shared.isDebugUser
                if !link.displayName.isEmpty || showsExtension {
                    Section("Account") {
                        if !link.displayName.isEmpty { Text(link.displayName) }
                        if showsExtension {
                            LabeledContent("Extension", value: link.sip.username)
                        }
                    }
                }
            }

            Section("Status") {
                RegistrationStatusView(status: session.status, state: store.state)
                if session.isMicrophoneRefused {
                    Button("Open Settings") {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }

            if session.needsLogin {
                Section("Session expired") {
                    Button("Log in again") { session.loginAgain() }
                        .disabled(session.isLoggingIn)
                    if let error = session.loginError {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }

            if let call = store.call {
                Section("Call") {
                    Text(call.isConnected ? "In call with \(call.caller)" : "Incoming call from \(call.caller)")
                    Button("End call", role: .destructive) { CallManager.shared.endCall() }
                }
            }

            if AuthStore.shared.isDebugUser {
                WakeLogSection()
            }

            Section {
                AcknowledgementsButton()
            }

            Section {
                LogoutButton()
                    .disabled(store.call != nil)
            }
        }
    }
}

/// Diagnostics, so it stays in English like the SIP reasons.
private struct WakeLogSection: View {
    private let timeline = WakeTimeline.shared

    var body: some View {
        Section {
            if timeline.lines.isEmpty {
                Text(verbatim: "No wake yet").foregroundStyle(.secondary)
            }
            ForEach(Array(timeline.lines.enumerated()), id: \.offset) { _, line in
                Text(verbatim: line)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }
        } header: {
            Text(verbatim: "Last wake")
        }
    }
}

private struct AcknowledgementsButton: View {
    @State private var isShowing = false

    var body: some View {
        Button("Acknowledgements") { isShowing = true }
            .sheet(isPresented: $isShowing) { AcknowledgementsView() }
    }
}

private struct LogoutButton: View {
    @State private var isConfirming = false

    private let session = AppSession.shared

    var body: some View {
        Button("Log out", role: .destructive) { isConfirming = true }
            .disabled(session.isLoggingOut)
            .confirmationDialog(
                "You'll stop receiving door calls on this phone",
                isPresented: $isConfirming,
                titleVisibility: .visible
            ) {
                Button("Log out", role: .destructive) { session.logout() }
            }
    }
}

private struct RegistrationStatusView: View {
    let status: AppSession.Status
    let state: RegistrationState

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: "circle.fill").foregroundStyle(colour)
            }
            if let detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            if case .failed(nil) = status, case .failed(let failure) = state, let hint = failure.hint {
                Text(hint).font(.footnote)
            }
        }
    }

    private var title: LocalizedStringKey {
        switch status {
        case .ready: "Ready for calls"
        case .connecting: "Connecting…"
        case .failed: "Can't receive calls"
        }
    }

    private var detail: String? {
        if case .failed(let reason?) = status { return reason }
        switch state {
        case .registered(let expirySeconds): return String(localized: "Expiry \(expirySeconds) s")
        case .failed(let failure):
            let text = failure.code == 0 ? failure.reason : "\(failure.code) \(failure.reason)"
            return failure.isRetrying ? String(localized: "\(text), retrying") : text
        case .notRegistered, .registering: return nil
        }
    }

    private var colour: Color {
        switch status {
        case .ready: .green
        case .connecting: .orange
        case .failed: .red
        }
    }
}

#Preview {
    ContentView()
}
