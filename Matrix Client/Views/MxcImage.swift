import SwiftUI
import MatrixRustSDK

/// Loads a `MediaSource` (mxc URI or encrypted file ref) as a thumbnail via the SDK.
/// Encrypted attachments require the SDK's MediaSource, not just the mxc URL — `fromUrl`
/// would lose the decryption keys.
struct MxcImage: View {
    let source: MediaSource?
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
        .task(id: sourceKey) { await load() }
    }

    /// Use the underlying mxc URL as the identity — same media → same key, so .task only
    /// re-fires when the actual content changes.
    private var sourceKey: String { source?.url() ?? "" }

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
        guard let source, let client = session.client else { failed = true; return }
        do {
            let data = try await client.getMediaThumbnail(
                mediaSource: source,
                width: UInt64(maxWidth * 2),
                height: UInt64(maxHeight * 2)
            )
            if let nsImage = NSImage(data: data) { self.image = nsImage }
            else { self.failed = true }
        } catch {
            // Some servers don't support thumbnails for all content; try full payload.
            do {
                let data = try await client.getMediaContent(mediaSource: source)
                if let nsImage = NSImage(data: data) { self.image = nsImage }
                else { self.failed = true }
            } catch {
                self.failed = true
            }
        }
    }
}
