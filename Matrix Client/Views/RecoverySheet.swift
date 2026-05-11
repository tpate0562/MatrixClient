import SwiftUI
import MatrixRustSDK

/// Sheet for recovering encryption identity + key backup. The user pastes their recovery
/// key (or recovery passphrase — the SDK accepts either as the `recoveryKey:` argument).
struct RecoverySheet: View {
    @EnvironmentObject private var session: MatrixSession
    @Environment(\.dismiss) private var dismiss

    @State private var key: String = ""
    @State private var working = false
    @State private var done = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "key.fill").font(.title2).foregroundStyle(.tint)
                Text("Recover Encryption Keys").font(.title2.bold())
            }
            Text("""
            Paste the recovery key or passphrase you set up in Element \
            (Settings → Security & Privacy → Set up Recovery). \
            This restores your identity and downloads room keys from backup so \
            encrypted messages can be decrypted on this device.
            """)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                Text("Recovery key or passphrase").font(.caption).foregroundStyle(.secondary)
                SecureField("EsK… or your passphrase", text: $key)
                    .textFieldStyle(.roundedBorder)
            }

            HStack {
                stateBadge
                Spacer()
            }

            if done {
                Label("Recovery completed. New keys will arrive on the next sync.", systemImage: "checkmark.seal.fill")
                    .foregroundStyle(.green)
                    .font(.callout)
            }

            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Close") { dismiss() }
                Button {
                    working = true
                    Task {
                        await session.recover(withKey: key)
                        working = false
                        if session.lastError == nil {
                            done = true
                        } else {
                            error = session.lastError
                        }
                    }
                } label: {
                    HStack {
                        if working { ProgressView().controlSize(.small) }
                        Text("Recover")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(working || key.isEmpty)
            }
        }
        .padding()
        .frame(width: 520)
    }

    @ViewBuilder
    private var stateBadge: some View {
        let (label, color): (String, Color) = {
            switch session.recoveryState {
            case .enabled:    return ("Recovery enabled", .green)
            case .disabled:   return ("Recovery disabled", .secondary)
            case .incomplete: return ("Recovery incomplete", .orange)
            case .unknown:    return ("Recovery state unknown", .gray)
            }
        }()
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).font(.caption).foregroundStyle(color)
        }
    }
}
