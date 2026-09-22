import SwiftUI
import MatrixRustSDK

struct RoomListView: View {
    @EnvironmentObject private var session: MatrixSession
    @Binding var selectedRoomId: String?
    @State private var filter: String = ""
    @State private var spacesExpanded: Bool = false

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

            if !joinedSpaces().isEmpty {
                spacesSection
            }

            List(selection: $selectedRoomId) {
                ForEach(filtered(), id: \.id) { vm in
                    RoomRow(vm: vm)
                        .tag(vm.id)
                        .contextMenu {
                            Button("Mark as Read") {
                                Task { await vm.markAsRead() }
                            }
                            Button("Leave Room", role: .destructive) {
                                Task { await vm.leave() }
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
            ForEach(Array(session.invites.values), id: \.id) { vm in
                HStack {
                    VStack(alignment: .leading) {
                        Text(vm.displayName).font(.callout)
                        Text(vm.id).font(.caption2).foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Button("Join") {
                        Task { await session.acceptInvite(vm.id) }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.mini)
                    Button("Reject") {
                        Task { await session.rejectInvite(vm.id) }
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

    /// Collapsible "Spaces" section. Spaces are tagged `m.space` rooms — they
    /// belong in their own list rather than mixed in with chat rooms. Tapping
    /// one selects it; the detail pane shows its (typically empty) timeline,
    /// which is enough to leave a space or see who's in it. Full child-room
    /// browsing would need the `/_matrix/client/v1/rooms/{roomId}/hierarchy`
    /// endpoint, which this SDK build doesn't expose directly.
    private var spacesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button {
                withAnimation(.easeInOut(duration: 0.15)) { spacesExpanded.toggle() }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: spacesExpanded ? "chevron.down" : "chevron.right")
                        .font(.caption2)
                    Text("Spaces (\(joinedSpaces().count))")
                        .font(.caption.bold())
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 12)

            if spacesExpanded {
                ForEach(joinedSpaces(), id: \.id) { vm in
                    HStack(spacing: 8) {
                        Avatar(name: vm.displayName, mxc: vm.avatarUrl, size: 22)
                        Text(vm.displayName).font(.callout).lineLimit(1)
                        Spacer()
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 3)
                    .background(
                        selectedRoomId == vm.id
                            ? Color.accentColor.opacity(0.15)
                            : Color.clear
                    )
                    .contentShape(Rectangle())
                    .onTapGesture { selectedRoomId = vm.id }
                    .contextMenu {
                        Button("Leave Space", role: .destructive) {
                            Task { await vm.leave() }
                        }
                    }
                }
            }
            Divider().padding(.top, 4)
        }
        .padding(.vertical, 6)
    }

    private func joinedSpaces() -> [RoomVM] {
        session.roomOrder.compactMap { session.rooms[$0] }
            .filter { $0.isSpace }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private func filtered() -> [RoomVM] {
        let base = session.roomOrder.compactMap { session.rooms[$0] }
        let f = filter.lowercased()
        return base.filter { vm in
            // Always hide spaces from the main chat list — they have their own section.
            if vm.isSpace { return false }
            switch section {
            case .all: break
            case .dms: if !vm.isDirect { return false }
            case .rooms: if vm.isDirect { return false }
            }
            if f.isEmpty { return true }
            return vm.displayName.lowercased().contains(f) ||
                   (vm.topic ?? "").lowercased().contains(f) ||
                   vm.id.lowercased().contains(f)
        }
    }
}

private struct RoomRow: View {
    @ObservedObject var vm: RoomVM

    var body: some View {
        // For DMs, show the other person's profile picture in place of the
        // room avatar (which is usually nil for 1:1 rooms anyway). Falls back
        // to the room avatar when the partner hasn't uploaded a picture, and
        // uses the partner's name for the colored-initials placeholder so the
        // fallback circle picks up the right initials + accent color.
        let isDM = vm.isDirect && vm.dmPartnerUserId != nil
        let avatarMxc = isDM ? (vm.dmPartnerAvatarUrl ?? vm.avatarUrl) : vm.avatarUrl
        let avatarName = isDM
            ? (vm.dmPartnerDisplayName ?? vm.dmPartnerUserId ?? vm.displayName)
            : vm.displayName
        return HStack(spacing: 10) {
            Avatar(name: avatarName, mxc: avatarMxc, size: 32)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    if vm.isDirect {
                        Image(systemName: "person.fill")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Text(vm.displayName)
                        .lineLimit(1)
                        .font(.callout.weight(.medium))
                    if vm.isEncrypted {
                        Image(systemName: "lock.fill")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                }
                if let topic = vm.topic, !topic.isEmpty {
                    Text(topic)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
        }
        .padding(.vertical, 2)
    }
}

/// Reusable avatar that loads an SDK-authenticated thumbnail via `client.getMediaThumbnail`.
struct Avatar: View {
    let name: String
    let mxc: String?
    let size: CGFloat
    @EnvironmentObject private var session: MatrixSession
    @State private var loaded: NSImage?

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded).resizable().scaledToFill()
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
        guard let mxc, let client = session.client, mxc.hasPrefix("mxc://") else { return }
        do {
            let source = try MediaSource.fromUrl(url: mxc)
            let data = try await client.getMediaThumbnail(
                mediaSource: source,
                width: UInt64(size * 2),
                height: UInt64(size * 2)
            )
            if let img = NSImage(data: data) { self.loaded = img }
        } catch {
            // Try full content as a fallback.
            if let source = try? MediaSource.fromUrl(url: mxc),
               let data = try? await client.getMediaContent(mediaSource: source),
               let img = NSImage(data: data) {
                self.loaded = img
            }
        }
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
