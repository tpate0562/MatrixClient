import SwiftUI
import MatrixRustSDK

struct RoomAdminView: View {
    @ObservedObject var room: RoomVM
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
                    .font(.caption).foregroundStyle(.red)
                    .padding(.bottom, 8)
            }
        }
        .frame(width: 640, height: 560)
        .task {
            nameDraft = room.displayName
            topicDraft = room.topic ?? ""
            await room.loadMembers()
        }
    }

    // MARK: - General

    @ViewBuilder
    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            Field(label: "Name") {
                HStack {
                    TextField("Room name", text: $nameDraft).textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task { await room.setName(nameDraft) }
                    }
                    .disabled(nameDraft == room.displayName)
                }
            }
            Field(label: "Topic") {
                HStack(alignment: .top) {
                    TextField("Topic", text: $topicDraft, axis: .vertical)
                        .lineLimit(1...4)
                        .textFieldStyle(.roundedBorder)
                    Button("Save") {
                        Task { await room.setTopic(topicDraft) }
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
                    Text("Joined: \(room.joinedMembersCount)")
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
                        await room.invite(inviteUser)
                        inviteUser = ""
                    }
                }
                .disabled(inviteUser.isEmpty)
            }
            Divider()
            if room.membersLoaded {
                ForEach(sortedMembers, id: \.userId) { m in
                    memberRow(m)
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading members…").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var sortedMembers: [RoomMember] {
        room.members.values
            .filter { $0.membership == .join }
            .sorted { a, b in
                let la = room.powerLevel(of: a.userId)
                let lb = room.powerLevel(of: b.userId)
                if la != lb { return la > lb }
                return (a.displayName ?? a.userId) < (b.displayName ?? b.userId)
            }
    }

    @ViewBuilder
    private func memberRow(_ m: RoomMember) -> some View {
        let level = room.powerLevel(of: m.userId)
        let role = roleName(level)
        HStack {
            Avatar(name: m.displayName ?? m.userId, mxc: m.avatarUrl, size: 28)
            VStack(alignment: .leading) {
                Text(m.displayName ?? m.userId).font(.callout.bold())
                Text(m.userId).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(role) · \(level)").font(.caption).foregroundStyle(.secondary)
            Menu {
                if room.myPowerLevel >= 100 || (room.myPowerLevel > level && room.myPowerLevel >= 50) {
                    Button("Make Admin (100)") { Task { await room.setPower(m.userId, level: 100) } }
                    Button("Make Moderator (50)") { Task { await room.setPower(m.userId, level: 50) } }
                    Button("Reset to Default (0)") { Task { await room.setPower(m.userId, level: 0) } }
                }
                if room.myPowerLevel > level {
                    Divider()
                    Button("Kick") { Task { await room.kick(m.userId) } }
                    Button("Ban", role: .destructive) { Task { await room.ban(m.userId) } }
                }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.borderlessButton)
            .frame(width: 32)
        }
        .padding(.vertical, 2)
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
                    await room.leave()
                    dismiss()
                }
            } label: {
                Label("Leave Room", systemImage: "rectangle.portrait.and.arrow.right")
            }
        }
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
