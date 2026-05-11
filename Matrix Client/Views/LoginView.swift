import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: MatrixSession
    @State private var homeserver: String = "matrix.org"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var loggingIn = false
    @State private var showTokenSheet = false
    @State private var ssoSigningIn = false
    @FocusState private var focused: Field?

    enum Field { case homeserver, user, password }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(.tint)
                Text("Matrix Client")
                    .font(.largeTitle.bold())
                Text("Sign in to your homeserver")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 12) {
                LabeledField(label: "Homeserver", text: $homeserver, placeholder: "matrix.org")
                    .focused($focused, equals: .homeserver)
                LabeledField(label: "Username", text: $username, placeholder: "@you:matrix.org or 'you'")
                    .focused($focused, equals: .user)
                LabeledSecure(label: "Password", text: $password)
                    .focused($focused, equals: .password)
            }
            .frame(maxWidth: 360)

            if let err = session.lastError {
                Text(err)
                    .font(.callout)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Button(action: signIn) {
                HStack {
                    if loggingIn { ProgressView().controlSize(.small) }
                    Text("Sign In")
                }
                .frame(maxWidth: 200)
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(loggingIn || username.isEmpty || password.isEmpty)

            Button(action: signInSSO) {
                HStack {
                    if ssoSigningIn { ProgressView().controlSize(.small) }
                    Image(systemName: "globe")
                    Text("Continue with SSO / Single Sign-On")
                }
                .frame(maxWidth: 260)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(ssoSigningIn || homeserver.isEmpty)

            Button("Sign in with Access Token") { showTokenSheet = true }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.blue)

            Text("End-to-end encryption is provided by the Matrix Rust SDK. Use Settings → Recover to restore your key backup so old messages decrypt.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { focused = .user }
        .sheet(isPresented: $showTokenSheet) {
            TokenLoginSheet(homeserver: homeserver)
        }
    }

    private func signIn() {
        loggingIn = true
        Task {
            await session.login(homeserverInput: homeserver, user: username, password: password)
            loggingIn = false
        }
    }

    private func signInSSO() {
        ssoSigningIn = true
        Task {
            do {
                let (loginURL, scheme) = try await session.beginOIDC(homeserverInput: homeserver)
                let callback = try await AuthWebSession.start(url: loginURL, callbackURLScheme: scheme)
                await session.completeOIDC(callbackURL: callback)
            } catch {
                await session.cancelOIDC()
                // Session error already surfaces via session.lastError on most paths;
                // catch ASWebAuthenticationSession cancellations explicitly so they look
                // friendly.
                let ns = error as NSError
                if ns.domain == "com.apple.AuthenticationServices.WebAuthenticationSession" {
                    // user closed the auth window — nothing to do
                } else {
                    session.lastError = describe(error)
                }
            }
            ssoSigningIn = false
        }
    }
}

private struct LabeledField: View {
    let label: String
    @Binding var text: String
    let placeholder: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            TextField(placeholder, text: $text)
                .textFieldStyle(.roundedBorder)
                .autocorrectionDisabled()
        }
    }
}

private struct LabeledSecure: View {
    let label: String
    @Binding var text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            SecureField("", text: $text)
                .textFieldStyle(.roundedBorder)
        }
    }
}

private struct TokenLoginSheet: View {
    @EnvironmentObject private var session: MatrixSession
    @Environment(\.dismiss) private var dismiss

    @State var homeserver: String
    @State private var token: String = ""
    @State private var working = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Sign in with Access Token").font(.title2.bold())
            Text("Paste an existing access token (e.g. from Element → Settings → Help & About).")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Text("Homeserver").font(.caption).foregroundStyle(.secondary)
                TextField("matrix.org", text: $homeserver)
                    .textFieldStyle(.roundedBorder)
                    .autocorrectionDisabled()
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Access Token").font(.caption).foregroundStyle(.secondary)
                SecureField("syt_…", text: $token)
                    .textFieldStyle(.roundedBorder)
            }

            if let err = session.lastError {
                Text(err).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button {
                    working = true
                    Task {
                        await session.loginWithToken(homeserverInput: homeserver, accessToken: token)
                        working = false
                        if session.isAuthenticated { dismiss() }
                    }
                } label: {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text("Sign In")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working || token.isEmpty || homeserver.isEmpty)
            }
        }
        .padding()
        .frame(width: 460)
    }
}
