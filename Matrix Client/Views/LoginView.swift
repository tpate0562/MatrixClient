import SwiftUI

struct LoginView: View {
    @EnvironmentObject private var session: MatrixSession
    @State private var homeserver: String = "matrix.org"
    @State private var username: String = ""
    @State private var password: String = ""
    @State private var loggingIn = false
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

            Text("Encryption is detected but not yet decoded — encrypted messages show as 🔒 placeholders.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .onAppear { focused = .user }
    }

    private func signIn() {
        loggingIn = true
        Task {
            await session.login(homeserverInput: homeserver, user: username, password: password)
            loggingIn = false
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
