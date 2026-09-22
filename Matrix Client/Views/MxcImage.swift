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
                let size = fittedSize(for: image)
                Image(nsImage: image)
                    .resizable()
                    .frame(width: size.width, height: size.height)
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

    /// Aspect-fit the image into maxWidth×maxHeight and return an *exact* size so the
    /// view hugs the bitmap. `.frame(maxWidth:maxHeight:)` + `.scaledToFit()` instead
    /// leaves the frame at its full max width and centers a narrower (portrait) image
    /// inside it — which reads as a big empty gap on the leading edge. Never upscale
    /// past the source's natural size.
    private func fittedSize(for image: NSImage) -> CGSize {
        let px = pixelSize(of: image)
        guard px.width > 0, px.height > 0 else {
            return CGSize(width: maxWidth, height: maxHeight)
        }
        let scale = min(maxWidth / px.width, maxHeight / px.height, 1)
        return CGSize(width: (px.width * scale).rounded(),
                      height: (px.height * scale).rounded())
    }

    /// True pixel dimensions, preferring the bitmap representation over `NSImage.size`
    /// (which can be DPI-adjusted and misreport the real resolution).
    private func pixelSize(of image: NSImage) -> CGSize {
        if let rep = image.representations.first {
            let w = rep.pixelsWide, h = rep.pixelsHigh
            if w > 0, h > 0 { return CGSize(width: w, height: h) }
        }
        return image.size
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

        // Try a server-rendered thumbnail first (cheap, small). Fall through to
        // the full payload whenever the thumbnail path yields no *decodable*
        // image — not just when it throws. Older media often comes back with no
        // thumbnail, or in a thumbnail format NSImage can't decode, in which
        // case the full content still loads fine. Each fetch re-pulls from the
        // server when the SDK's media cache no longer has the bytes.
        if let thumb = try? await client.getMediaThumbnail(
            mediaSource: source,
            width: UInt64(maxWidth * 2),
            height: UInt64(maxHeight * 2)
        ), let nsImage = NSImage(data: thumb) {
            self.image = nsImage
            return
        }

        if let full = try? await client.getMediaContent(mediaSource: source),
           let nsImage = NSImage(data: full) {
            self.image = nsImage
            return
        }

        // Don't flash the error placeholder when the load was simply cancelled
        // (view scrolled away / source changed) — the next load resets state.
        if Task.isCancelled { return }
        self.failed = true
    }
}

/// Download a media attachment to a temp file and hand it to the system
/// (Preview/QuickLink). Shared by the live message row and the cached-history
/// row so both open images/files the same way. The bytes are re-fetched from
/// the server when the SDK's media cache no longer holds them.
func openMediaExternally(source: MediaSource, filename: String, client: Client?) {
    guard let client else { return }
    // Detach so file I/O (network fetch + disk copy) never blocks the main thread.
    Task.detached(priority: .userInitiated) {
        do {
            let handle = try await client.getMediaFile(
                mediaSource: source,
                filename: filename,
                mimeType: "application/octet-stream",
                useCache: true,
                tempDir: nil
            )
            let sdkUrl = URL(fileURLWithPath: try handle.path())
            // The SDK's MediaFile handle deletes the file when deallocated, so
            // copy it somewhere of our own first so it survives long enough to open.
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
            let destUrl = tmp.appendingPathComponent(filename)
            if FileManager.default.fileExists(atPath: destUrl.path) {
                try FileManager.default.removeItem(at: destUrl)
            }
            try FileManager.default.copyItem(at: sdkUrl, to: destUrl)
            await MainActor.run { NSWorkspace.shared.open(destUrl) }
        } catch {
            // Best-effort fallback: write raw bytes to a temp file.
            if let data = try? await client.getMediaContent(mediaSource: source) {
                let tmp = FileManager.default.temporaryDirectory
                    .appendingPathComponent(UUID().uuidString, isDirectory: true)
                try? FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
                let url = tmp.appendingPathComponent(filename)
                try? data.write(to: url)
                await MainActor.run { NSWorkspace.shared.open(url) }
            }
        }
    }
}
