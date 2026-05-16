import SwiftUI
import MatrixRustSDK

struct VerificationSheet: View {
    @ObservedObject var controller: VerificationController
    @EnvironmentObject private var session: MatrixSession
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 16) {
            content
        }
        .padding(24)
        .frame(width: 480, height: 380)
        .onChange(of: controller.phase) { _, phase in
            // Close automatically on terminal states after a brief pause.
            switch phase {
            case .finished, .cancelled, .failed:
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    controller.dismiss()
                }
            default: break
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch controller.phase {
        case .idle:
            placeholder
        case .incomingRequest(let senderId, let deviceId, let deviceName):
            incomingRequestView(senderId: senderId, deviceId: deviceId, deviceName: deviceName)
        case .acknowledged:
            waitingView(label: "Waiting for emojis…")
        case .sasStarting:
            waitingView(label: "Waiting for the other device…")
        case .emojis(let items):
            emojisView(items: items)
        case .finished:
            terminal(systemImage: "checkmark.seal.fill", color: .green, title: "Verified", subtitle: "This device is now cross-signed and trusted.")
        case .cancelled(let reason):
            terminal(systemImage: "xmark.circle.fill", color: .secondary, title: "Cancelled", subtitle: reason ?? "Verification was cancelled.")
        case .failed(let reason):
            terminal(systemImage: "exclamationmark.triangle.fill", color: .red, title: "Failed", subtitle: reason ?? "Verification failed.")
        }
    }

    // MARK: - States

    private var placeholder: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.shield").font(.system(size: 60)).foregroundStyle(.tint)
            Text("Verify this device").font(.title2.bold())

            if session.recoveryState != .enabled {
                // Recovery is not set up — SAS verification will fail.
                VStack(spacing: 6) {
                    Label("Recovery keys needed first", systemImage: "exclamationmark.triangle.fill")
                        .font(.callout.bold())
                        .foregroundStyle(.orange)
                    Text("Interactive verification requires your recovery key. Close this sheet, choose \"Recover Encryption Keys\" from the menu, and enter your recovery key. The device will verify itself automatically.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .font(.caption)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(10)
                .background(Color.orange.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                Text("Open Element on another signed-in device, find this session in Settings \u{2192} Sessions, and tap Verify. You\u{2019}ll then compare emojis here.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Close") { controller.dismiss(); dismiss() }
                Spacer()
                Button("Request from this device") {
                    Task { await controller.requestVerification() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(session.recoveryState != .enabled)
            }
        }
    }

    private func incomingRequestView(senderId: String, deviceId: String, deviceName: String?) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "person.badge.shield.checkmark").font(.system(size: 56)).foregroundStyle(.tint)
            Text("Verification Request").font(.title2.bold())
            VStack(spacing: 4) {
                Text(deviceName ?? deviceId).font(.callout.bold())
                Text(senderId).font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            Text("Accept to compare emojis between the two devices.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Cancel", role: .destructive) {
                    Task { await controller.cancel() }
                }
                Spacer()
                Button("Accept") {
                    Task { await controller.acceptIncoming() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func waitingView(label: String) -> some View {
        VStack(spacing: 12) {
            ProgressView().controlSize(.large)
            Text(label).foregroundStyle(.secondary)
            Button("Cancel") { Task { await controller.cancel() } }
        }
    }

    private func emojisView(items: [VerificationController.Emoji]) -> some View {
        VStack(spacing: 16) {
            Text("Compare Emojis").font(.title2.bold())
            Text("Make sure the same emojis appear on both devices, in the same order.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            let columns = Array(repeating: GridItem(.flexible(), spacing: 8), count: 4)
            LazyVGrid(columns: columns, spacing: 12) {
                ForEach(items.indices, id: \.self) { idx in
                    let e = items[idx]
                    VStack(spacing: 4) {
                        Text(e.symbol).font(.system(size: 38))
                        Text(e.description).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.08))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            HStack {
                Button("They don't match", role: .destructive) {
                    Task { await controller.declineMatch() }
                }
                Spacer()
                Button("They match") {
                    Task { await controller.confirmMatch() }
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func terminal(systemImage: String, color: Color, title: String, subtitle: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 64)).foregroundStyle(color)
            Text(title).font(.title2.bold())
            Text(subtitle)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Close") { controller.dismiss(); dismiss() }
        }
    }
}
