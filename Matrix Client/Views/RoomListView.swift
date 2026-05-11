import SwiftUI

struct RoomListView: View {
    @EnvironmentObject private var session: MatrixSession
    @Binding var selectedRoomId: String?
    @State private var filter: String = ""

    private enum Section: String, CaseIterable, Identifiable {
        case all = "All", dms = "Direct", rooms = "Rooms"
        var id: String { rawValue }
    }
    @State private var section: Section = .all

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $section) {
                ForEach(Section.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)

            if !session.invites.isEmpty {
                invitesSection
            }

            List(selection: $selectedRoomId) {
                ForEach(filtered(), id: \.id) { room in
                    RoomRow(room: room)
                        .tag(room.id)
                        .contextMenu {
                            Button("Mark as Read") {
                                Task { await session.sendReadReceipt(roomId: room.id) }
                            }
                            Button("Leave Room", role: .destructive) {
                                Task { await session.leave(roomId: room.id) }
                            }
                        }
                }
            }
            .searchable(text: $filter, placement: .sidebar, prompt: "Filter rooms")
        }
    }

    private var invitesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Invites").font(.caption.bold()).foregroundStyle(.secondary)
                .padding(.horizontal, 12)
            ForEach(Array(session.invites.values), id: \.id) { room in
                HStack {
                    VStack(alignment: .leading) {
                        Text(room.displayName).font(.callout)
                        Text(room.id).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Join") {
                        Task { await session.acceptInvite(room.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    Button("Reject") {
                        Task { await session.rejectInvite(room.id) }
                    }
                    .controlSize(.mini)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            Divider()
        }
        .padding(.vertical, 6)
    }

    private func filtered() -> [Room] {
        let base = session.roomOrder.compactMap { session.rooms[$0] }
        let f = filter.lowercased()
        return base.filter { room in
            // Section filter.
            switch section {
            case .all: break
            case .dms: if !room.isDirect { return false }
            case .rooms: if room.isDirect { return false }
            }
            // Text filter.
            if f.isEmpty { return true }
            return room.displayName.lowercased().contains(f) ||
                   (room.topic ?? "").lowercased().contains(f) ||
                   room.id.lowercased().contains(f)
        }
    }
}

private struct RoomRow: View {
    @ObservedObject var room: Room

    var body: some View {
        HStack(spacing: 10) {
            Avatar(name: room.displayName, mxc: room.avatarMxc, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if room.isDirect {
                        Image(systemName: "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(room.displayName)
                        .lineLimit(1)
                        .font(.callout.weight(.medium))
                    if room.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let preview = lastPreview() {
                    Text(preview)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if room.unreadCount > 0 {
                Text("\(room.unreadCount)")
                    .font(.caption.bold())
                    .padding(.horizontal, 6).padding(.vertical, 2)
                    .background(room.highlightCount > 0 ? Color.red : Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
        .padding(.vertical, 2)
    }

    private func lastPreview() -> String? {
        for ev in room.timeline.reversed() {
            switch ev.type {
            case "m.room.message":
                if let body = ev.messageBody { return body }
            case "m.room.encrypted":
                return "🔒 Encrypted message"
            default: continue
            }
        }
        return nil
    }
}

struct Avatar: View {
    let name: String
    let mxc: String?
    let size: CGFloat
    @EnvironmentObject private var session: MatrixSession
    @State private var loaded: Image?

    var body: some View {
        Group {
            if let loaded {
                loaded.resizable().scaledToFill()
            } else {
                ZStack {
                    Circle().fill(colorForName(name))
                    Text(initials(name))
                        .font(.system(size: size * 0.4, weight: .semibold))
                        .foregroundColor(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .task(id: mxc) { await load() }
    }

    private func load() async {
        loaded = nil
        guard let mxc, let creds = session.credentials else { return }
        let api = session.api
        guard let url = await api.thumbnailURL(homeserver: creds.homeserverURL, mxc: mxc, size: Int(size * 2)) else { return }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let nsImage = NSImage(data: data) {
                loaded = Image(nsImage: nsImage)
            }
        } catch {}
    }

    private func initials(_ s: String) -> String {
        let cleaned = s.trimmingCharacters(in: .whitespaces)
        let stripped = cleaned.hasPrefix("@") || cleaned.hasPrefix("#") || cleaned.hasPrefix("!")
            ? String(cleaned.dropFirst()) : cleaned
        let parts = stripped.split(whereSeparator: { " :_-".contains($0) })
        let chars = parts.prefix(2).compactMap { $0.first.map(String.init) }
        return chars.joined().uppercased()
    }

    private func colorForName(_ s: String) -> Color {
        let palette: [Color] = [.blue, .green, .orange, .pink, .purple, .red, .teal, .indigo, .mint, .yellow]
        var hash = 0
        for u in s.unicodeScalars { hash = hash &+ Int(u.value) }
        return palette[abs(hash) % palette.count]
    }
}
