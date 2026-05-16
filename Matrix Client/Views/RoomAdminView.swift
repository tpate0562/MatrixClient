import SwiftUI
import MatrixRustSDK
import UniformTypeIdentifiers

struct RoomAdminView: View {
    @ObservedObject var room: RoomVM
    @EnvironmentObject private var session: MatrixSession
    @EnvironmentObject private var nicknames: NicknameStore
    @Environment(\.dismiss) private var dismiss

    @State private var nameDraft: String = ""
    @State private var topicDraft: String = ""
    @State private var inviteUser: String = ""
    @State private var actionError: String?
    @State private var nicknameTarget: NicknameTarget?

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
        .sheet(item: $nicknameTarget) { target in
            NicknameEditor(userId: target.userId, currentName: target.fallbackName)
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
            Field(label: "Export") {
                Button("Export Chat as Text") {
                    exportChat()
                }
            }
        }
    }

    private func exportChat() {
        var lines = [String]()
        lines.append("Export of Room: \(room.displayName)")
        lines.append("ID: \(room.id)")
        lines.append(String(repeating: "=", count: 40))
        
        let df = DateFormatter()
        df.dateStyle = .short
        df.timeStyle = .short

        for item in room.items {
            if let event = item.asEvent() {
                let sender = nicknames.displayName(for: event.sender, fallback: event.sender)
                let date = Date(timeIntervalSince1970: TimeInterval(event.timestamp) / 1000.0)
                var body = ""
                
                if case .msgLike(let content) = event.content, case .message(let msg) = content.kind {
                    switch msg.msgType {
                    case .text(let t): body = t.body
                    case .emote(let e): body = "* \(e.body)"
                    case .image(let img): body = "[Image: \(img.filename)]"
                    case .video(let v): body = "[Video: \(v.filename)]"
                    case .audio(let a): body = "[Audio: \(a.filename)]"
                    case .file(let f): body = "[File: \(f.filename)]"
                    case .notice(let n): body = "[Notice: \(n.body)]"
                    default: body = "[Media]"
                    }
                } else if case .roomMembership(_, _, let change, _) = event.content {
                    body = "[Membership change: \(String(describing: change ?? .left))]"
                }
                
                if !body.isEmpty {
                    lines.append("[\(df.string(from: date))] \(sender): \(body)")
                }
            }
        }
        
        let output = lines.joined(separator: "\n")
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = "ChatExport-\(room.displayName.prefix(20)).txt"
        if panel.runModal() == .OK, let url = panel.url {
            try? output.write(to: url, atomically: true, encoding: .utf8)
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
        let display = nicknames.displayName(for: m.userId, fallback: m.displayName)
        HStack {
            Avatar(name: display, mxc: m.avatarUrl, size: 28)
            VStack(alignment: .leading) {
                HStack(spacing: 4) {
                    Text(display).font(.callout.bold())
                    if nicknames.nickname(for: m.userId) != nil {
                        Image(systemName: "person.text.rectangle")
                            .font(.caption2)
                            .foregroundStyle(.tint)
                            .help("Local nickname set")
                    }
                }
                Text(m.userId).font(.caption2).foregroundStyle(.tertiary)
            }
            Spacer()
            Text("\(role) · \(level)").font(.caption).foregroundStyle(.secondary)
            Menu {
                Button("Set Nickname…") {
                    nicknameTarget = NicknameTarget(userId: m.userId, fallbackName: m.displayName ?? m.userId)
                }
                Divider()
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
