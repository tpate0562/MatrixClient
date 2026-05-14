import SwiftUI
import MatrixRustSDK

struct MainView: View {
    @EnvironmentObject private var session: MatrixSession
    @State private var selectedRoomId: String?
    @State private var showCreateRoom = false
    @State private var roomCreationMode: CreateRoomView.Mode = .room
    @State private var showJoinRoom = false
    @State private var joinAlias: String = ""
    @State private var showRecovery = false
    @State private var showVerify = false

    var body: some View {
        NavigationSplitView {
            RoomListView(selectedRoomId: $selectedRoomId)
                .frame(minWidth: 240)
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Menu {
                            Button("New Direct Message") {
                                roomCreationMode = .dm
                                showCreateRoom = true
                            }
                            Button("New Room") {
                                roomCreationMode = .room
                                showCreateRoom = true
                            }
                            Divider()
                            Button("Join Room by ID/Alias…") { showJoinRoom = true }
                            Divider()
                            Button("Verify This Device…") { showVerify = true }
                            if session.recoveryState != .enabled {
                                Button("Recover Encryption Keys…") { showRecovery = true }
                            }
                            Divider()
                            Button("Reset sync cache…") {
                                Task { await session.resetSdkStore() }
                            }
                        } label: {
                            Label("New", systemImage: "square.and.pencil")
                        }
                    }
                }
        } detail: {
            if let id = selectedRoomId, let vm = session.rooms[id] {
                RoomDetailView(room: vm)
                    .id(id)
            } else {
                EmptyDetailView()
            }
        }
        .background {
            // Hidden buttons that own the Cmd+↑ / Cmd+↓ shortcuts. Hidden so they don't render
            // visibly, but the keyboard shortcuts still fire.
            Group {
                Button("Previous Room") { selectAdjacent(offset: -1) }
                    .keyboardShortcut(.upArrow, modifiers: .command)
                Button("Next Room") { selectAdjacent(offset: 1) }
                    .keyboardShortcut(.downArrow, modifiers: .command)
            }
            .opacity(0)
            .allowsHitTesting(false)
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
                Task { await session.joinByAliasOrId(alias) }
            } cancel: {
                showJoinRoom = false
            }
        }
        .sheet(isPresented: $showRecovery) {
            RecoverySheet()
        }
        .sheet(isPresented: Binding(
            get: { showVerify || session.verification?.presented == true },
            set: { newValue in
                if !newValue {
                    showVerify = false
                    session.verification?.presented = false
                }
            }
        )) {
            if let vc = session.verification {
                VerificationSheet(controller: vc)
            } else {
                Text("Verification not ready").padding()
            }
        }
    }

    private func selectAdjacent(offset: Int) {
        let order = session.roomOrder
        guard !order.isEmpty else { return }
        if let current = selectedRoomId, let idx = order.firstIndex(of: current) {
            let next = (idx + offset).clamped(to: 0...(order.count - 1))
            selectedRoomId = order[next]
        } else {
            selectedRoomId = order.first
        }
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
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
            HStack(spacing: 6) {
                stateDot
                Text(stateLabel).foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                verificationDot
                Text(verificationLabel).font(.caption).foregroundStyle(.tertiary)
            }
            if let me = session.currentUserId {
                Text(me).font(.caption).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var verificationDot: some View {
        let c: Color = {
            switch session.verificationState {
            case .verified: return .green
            case .unverified: return .orange
            case .unknown: return .gray
            }
        }()
        Circle().fill(c).frame(width: 8, height: 8)
    }

    private var verificationLabel: String {
        switch session.verificationState {
        case .verified: return "This device is verified"
        case .unverified: return "This device is not verified — use Recover Encryption Keys"
        case .unknown: return "Verification state unknown"
        }
    }

    @ViewBuilder
    private var stateDot: some View {
        let c: Color = {
            switch session.syncState {
            case .running: return .green
            case .idle, .terminated: return .yellow
            case .error: return .red
            case .offline: return .gray
            }
        }()
        Circle().fill(c).frame(width: 8, height: 8)
    }

    private var stateLabel: String {
        switch session.syncState {
        case .running: return "Syncing"
        case .idle: return "Idle"
        case .terminated: return "Sync stopped"
        case .error: return "Sync error"
        case .offline: return "Offline"
        }
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
