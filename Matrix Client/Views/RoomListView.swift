import SwiftUI
import MatrixRustSDK

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

    private func filtered() -> [RoomVM] {
        let base = session.roomOrder.compactMap { session.rooms[$0] }
        let f = filter.lowercased()
        return base.filter { vm in
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
        HStack(spacing: 10) {
            Avatar(name: vm.displayName, mxc: vm.avatarUrl, size: 32)
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
