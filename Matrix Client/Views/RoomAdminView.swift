import SwiftUI

struct RoomAdminView: View {
    @ObservedObject var room: Room
    @EnvironmentObject private var session: MatrixSession
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft: String = ""
    @State private var topicDraft: String = ""
    @State private var inviteUser: String = ""
    @State private var actionError: String?

    private enum Tab: String, CaseIterable, Identifiable {
        case general = "General", members = "Members", danger = "Danger"
        var id: String { rawValue }
    }
    @State private var tab: Tab = .general

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Room Settings").font(.headline)
                    Text(room.id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            ScrollView {
                Group {
                    switch tab {
                    case .general: generalTab
                    case .members: membersTab
                    case .danger: dangerTab
                    }
                }
                .padding()
            }
            if let actionError {
                Text(actionError)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 640, height: 560)
        .onAppear {
            nameDraft = room.name ?? ""
            topicDraft = room.topic ?? ""
        }
    }

    // MARK: - General

    private var canChangeName: Bool {
        myLevel >= room.powerLevelRequired(for: "m.room.name") &&
        myLevel >= (powerLevelsContent["events"]?["m.room.name"]?.intValue.map(Int.init) ?? 50)
    }

    @ViewBuilder
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Field(label: "Name") {
                HStack {
                    TextField("Room name", text: $nameDraft).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task { await session.setRoomName(nameDraft, roomId: room.id) }
                    }
                    .disabled(nameDraft == (room.name ?? ""))
                }
            }
            Field(label: "Topic") {
                HStack(alignment: .top) {
                    TextField("Topic", text: $topicDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task { await session.setRoomTopic(topicDraft, roomId: room.id) }
                    }
                    .disabled(topicDraft == (room.topic ?? ""))
                }
            }
            Field(label: "Properties") {
                VStack(alignment: .leading, spacing: 4) {
                    Label(room.isEncrypted ? "End-to-end encrypted" : "Not encrypted",
                          systemImage: room.isEncrypted ? "lock.fill" : "lock.open.fill")
                        .foregroundStyle(room.isEncrypted ? .green : .secondary)
                    Label(room.isDirect ? "Direct message" : "Group room",
                          systemImage: room.isDirect ? "person.fill" : "person.3.fill")
                    Text("Joined: \(room.joinedMemberCount) · Invited: \(room.invitedMemberCount)")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - Members

    @ViewBuilder
    private var membersTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("@user:server", text: $inviteUser)
                    .textFieldStyle(.roundedBorder)
                Button("Invite") {
                    Task {
                        do {
                            try await session.api.invite(roomId: room.id, userId: inviteUser)
                            inviteUser = ""
                        } catch { actionError = "\(error)" }
                    }
                }
                .disabled(inviteUser.isEmpty)
            }
            Divider()
            ForEach(sortedMembers, id: \.0) { (userId, ev) in
                memberRow(userId: userId, event: ev)
            }
        }
    }

    private var sortedMembers: [(String, MatrixEvent)] {
        room.members
            .filter { $0.value.content["membership"]?.stringValue == "join" }
            .sorted { a, b in
                let la = room.powerLevel(of: a.key)
                let lb = room.powerLevel(of: b.key)
                if la != lb { return la > lb }
                return (room.memberDisplayName(a.key) ?? a.key) < (room.memberDisplayName(b.key) ?? b.key)
            }
    }

    @ViewBuilder
    private func memberRow(userId: String, event: MatrixEvent) -> some View {
        let level = room.powerLevel(of: userId)
        let role = roleName(level)
        let canModerate = myLevel > level && myLevel >= room.powerLevelRequired(for: "kick")
        HStack {
            Avatar(name: room.memberDisplayName(userId) ?? userId,
                   mxc: room.memberAvatar(userId), size: 28)
            VStack(alignment: .leading) {
                Text(room.memberDisplayName(userId) ?? userId).font(.callout.bold())
                Text(userId).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(role) · \(level)").font(.caption).foregroundStyle(.secondary)
            Menu {
                if myLevel >= 100 || (myLevel > level && myLevel >= 50) {
                    Button("Make Admin (100)") { setLevel(userId, 100) }
                    Button("Make Moderator (50)") { setLevel(userId, 50) }
                    Button("Reset to Default (0)") { setLevel(userId, 0) }
                }
                if canModerate {
                    Divider()
                    Button("Kick") {
                        Task {
                            do { try await session.api.kick(roomId: room.id, userId: userId, reason: nil) }
                            catch { actionError = "\(error)" }
                        }
                    }
                    Button("Ban", role: .destructive) {
                        Task {
                            do { try await session.api.ban(roomId: room.id, userId: userId, reason: nil) }
                            catch { actionError = "\(error)" }
                        }
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(.vertical, 2)
    }

    private func setLevel(_ userId: String, _ level: Int) {
        Task { await session.setPowerLevel(userId: userId, level: level, roomId: room.id) }
    }

    private func roleName(_ level: Int) -> String {
        switch level {
        case 100...: return "Admin"
        case 50...:  return "Moderator"
        default:     return "Member"
        }
    }

    // MARK: - Danger

    @ViewBuilder
    private var dangerTab: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("These actions can't be undone.").foregroundStyle(.secondary)
            Button(role: .destructive) {
                Task {
                    await session.leave(roomId: room.id)
                    dismiss()
                }
            } label: {
                Label("Leave Room", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
    }

    // MARK: - Helpers

    private var myLevel: Int {
        guard let me = session.currentUserId else { return 0 }
        return room.powerLevel(of: me)
    }

    private var powerLevelsContent: JSONValue {
        room.stateByKey[Room.StateKey(type: "m.room.power_levels", stateKey: "")]?.content ?? .object([:])
    }
}

private struct Field<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.caption.bold()).foregroundStyle(.secondary)
            content
        }
    }
}
