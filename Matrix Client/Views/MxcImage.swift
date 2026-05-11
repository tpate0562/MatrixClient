import SwiftUI
import MatrixRustSDK

/// Loads an `mxc://` URI as a thumbnail through the SDK and renders it.
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
        guard let mxc, let client = session.client, mxc.hasPrefix("mxc://") else { failed = true; return }
        do {
            let source = try MediaSource.fromUrl(url: mxc)
            let data = try await client.getMediaThumbnail(
                mediaSource: source,
                width: UInt64(maxWidth * 2),
                height: UInt64(maxHeight * 2)
            )
            if let nsImage = NSImage(data: data) { self.image = nsImage }
            else { self.failed = true }
        } catch {
            // Some servers don't support thumbnails for all content; try full.
            if let source = try? MediaSource.fromUrl(url: mxc),
               let data = try? await client.getMediaContent(mediaSource: source),
               let img = NSImage(data: data) {
                self.image = img
            } else {
                self.failed = true
            }
        }
    }
}
