import SwiftUI

/// Loads an `mxc://` URI as an authenticated thumbnail and renders it.
struct MxcImage: View {
    let mxc: String?
    var maxWidth: CGFloat = 360
    var maxHeight: CGFloat = 280
    var corner: CGFloat = 8

    @EnvironmentObject private var session: MatrixSession
    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: maxWidth, maxHeight: maxHeight)
                    .clipShape(RoundedRectangle(cornerRadius: corner))
            } else if failed {
                placeholder(systemName: "photo.badge.exclamationmark")
            } else {
                placeholder(systemName: "photo")
                    .overlay { ProgressView().controlSize(.small) }
            }
        }
        .task(id: mxc) { await load() }
    }

    private func placeholder(systemName: String) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: corner)
                .fill(Color.secondary.opacity(0.15))
            Image(systemName: systemName)
                .font(.title)
                .foregroundStyle(.tertiary)
        }
        .frame(width: 200, height: 140)
    }

    private func load() async {
        image = nil; failed = false
        guard let mxc, let creds = session.credentials else { return }
        let api = session.api
        // Request a generous thumbnail; the server resizes for us.
        guard let url = await api.thumbnailURL(homeserver: creds.homeserverURL, mxc: mxc, size: Int(max(maxWidth, maxHeight) * 2)) else {
            failed = true; return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(creds.accessToken)", forHTTPHeaderField: "Authorization")
        do {
            let (data, _) = try await URLSession.shared.data(for: req)
            if let nsImage = NSImage(data: data) {
                self.image = nsImage
            } else {
                self.failed = true
            }
        } catch {
            self.failed = true
        }
    }
}
