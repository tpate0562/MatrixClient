import SwiftUI

struct CreateRoomView: View {
    enum Mode { case room, dm }
    let mode: Mode
    let onCreated: (String?) -> Void

    @EnvironmentObject private var session: MatrixSession
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var topic: String = ""
    @State private var inviteRaw: String = ""
    @State private var encrypted: Bool = false
    @State private var working = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(mode == .dm ? "New Direct Message" : "New Room")
                .font(.title2.bold())

            if mode == .room {
                LabeledContent("Name") {
                    TextField("Room name", text: $name).textFieldStyle(.roundedBorder)
                }
                LabeledContent("Topic") {
                    TextField("Optional", text: $topic).textFieldStyle(.roundedBorder)
                }
            }
            LabeledContent(mode == .dm ? "Invite" : "Invite (comma-separated)") {
                TextField(mode == .dm ? "@user:server" : "@a:server, @b:server", text: $inviteRaw)
                    .textFieldStyle(.roundedBorder)
            }
            Toggle("End-to-end encrypted", isOn: $encrypted)
                .help("Enabling encryption is permanent.")
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                Button(mode == .dm ? "Start DM" : "Create") {
                    create()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(working || (mode == .dm && inviteUserIds.isEmpty))
            }
        }
        .padding()
        .frame(width: 480)
    }

    private var inviteUserIds: [String] {
        inviteRaw.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    private func create() {
        working = true
        error = nil
        Task {
            let id = await session.createRoom(
                name: mode == .room && !name.isEmpty ? name : nil,
                topic: mode == .room && !topic.isEmpty ? topic : nil,
                isDirect: mode == .dm,
                invite: inviteUserIds,
                encrypted: encrypted
            )
            working = false
            if let id { onCreated(id); dismiss() }
            else { error = session.lastError ?? "Failed to create room" }
        }
    }
}
