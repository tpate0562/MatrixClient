import SwiftUI

struct MainView: View {
    @EnvironmentObject private var session: MatrixSession
    @State private var selectedRoomId: String?
    @State private var showCreateRoom = false
    @State private var showJoinRoom = false
    @State private var joinAlias: String = ""

    var body: some View {
        NavigationSplitView {
            RoomListView(selectedRoomId: $selectedRoomId)
                .frame(minWidth: 240)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Direct Message") {
                                showCreateRoom = true
                                roomCreationMode = .dm
                            }
                            Button("New Room") {
                                showCreateRoom = true
                                roomCreationMode = .room
                            }
                            Divider()
                            Button("Join Room by ID/Alias…") { showJoinRoom = true }
                        } label: {
                            Label("New", systemImage: "square.and.pencil")
                        }
                    }
                    ToolbarItem(placement: .navigation) {
                        Button {
                            Task { await session.logout() }
                        } label: {
                            Label("Sign Out", systemImage: "rectangle.portrait.and.arrow.right")
                        }
                        .help("Sign out")
                    }
                }
        } detail: {
            if let id = selectedRoomId, let room = session.rooms[id] {
                RoomDetailView(room: room)
                    .id(id)
            } else {
                EmptyDetailView()
            }
        }
        .sheet(isPresented: $showCreateRoom) {
            CreateRoomView(mode: roomCreationMode) { newId in
                if let newId { selectedRoomId = newId }
            }
        }
        .sheet(isPresented: $showJoinRoom) {
            JoinRoomSheet(alias: $joinAlias) {
                showJoinRoom = false
                let alias = joinAlias
                joinAlias = ""
                Task { await session.joinByAlias(alias) }
            } cancel: {
                showJoinRoom = false
            }
        }
    }

    @State private var roomCreationMode: CreateRoomView.Mode = .room
}

private struct EmptyDetailView: View {
    @EnvironmentObject private var session: MatrixSession

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 60))
                .foregroundStyle(.tertiary)
            Text("Select a room")
                .font(.title2)
                .foregroundStyle(.secondary)
            if session.syncing {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Syncing…").foregroundStyle(.tertiary)
                }
            }
            if let me = session.currentUserId {
                Text(me).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct JoinRoomSheet: View {
    @Binding var alias: String
    let join: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Join Room").font(.title2.bold())
            Text("Enter a room alias (`#room:server`) or room ID (`!id:server`).")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("#room:matrix.org", text: $alias)
                .textFieldStyle(.roundedBorder)
            HStack {
                Spacer()
                Button("Cancel", action: cancel)
                Button("Join", action: join)
                    .keyboardShortcut(.defaultAction)
                    .disabled(alias.isEmpty)
            }
        }
        .padding()
        .frame(width: 420)
    }
}
