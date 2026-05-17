import SwiftUI
import AppKit
import UniformTypeIdentifiers
import MatrixRustSDK

/// Keys the composer's autocomplete popup wants to intercept while it is open.
enum AutocompleteKey { case up, down, confirm, cancel }

/// Bridges SwiftUI ↔ the live NSTextView so the autocomplete UI can replace the
/// `@mention` / `:emoji:` token in place (keeps undo + caret handling correct).
@MainActor
final class ComposerController {
    weak var textView: InputTextView?

    func attach(_ tv: InputTextView) { textView = tv }

    /// Replace a UTF-16 range in the editor with `replacement`, leaving the caret
    /// just after the inserted text.
    func replace(_ range: NSRange, with replacement: String) {
        guard let tv = textView else { return }
        let ns = tv.string as NSString
        let loc = min(max(0, range.location), ns.length)
        let len = min(max(0, range.length), ns.length - loc)
        let safe = NSRange(location: loc, length: len)
        if tv.shouldChangeText(in: safe, replacementString: replacement) {
            tv.textStorage?.replaceCharacters(in: safe, with: replacement)
            tv.didChangeText()
        }
        let newLoc = safe.location + (replacement as NSString).length
        tv.setSelectedRange(NSRange(location: newLoc, length: 0))
        tv.scrollRangeToVisible(tv.selectedRange())
    }
}

// MARK: - Autocomplete state

enum ACKind { case mention, emoji }

struct ACEntry: Identifiable {
    let title: String
    let subtitle: String?
    let avatarName: String?
    let avatarMxc: String?
    let glyph: String?          // emoji glyph for emoji rows
    let insert: String
    // Stable across keystrokes (same member/emoji keeps its row → no flicker).
    var id: String { "\(title)\u{1}\(subtitle ?? "")" }
}

struct AutocompleteState {
    var kind: ACKind
    var entries: [ACEntry]
    var selected: Int
    var start: Int              // UTF-16 offset of the token start
    var end: Int                // UTF-16 offset of the caret
}

struct MessageComposer: View {
    @Binding var text: String
    @Binding var replyingToId: String?
    @Binding var editingId: String?
    @ObservedObject var room: RoomVM
    let onSend: () -> Void
    let onEmoji: () -> Void
    let onAttach: ([URL]) -> Void
    let onPasteData: (Data, String, String) -> Void  // data, filename, mime

    @FocusState private var focused: Bool
    @State private var lastTypingSent: Date?
    @State private var stopTask: Task<Void, Never>?
    @State private var showFilePicker = false
    @State private var autocomplete: AutocompleteState?
    @State private var controller = ComposerController()

    var body: some View {
        VStack(spacing: 4) {
            if let replyingToId {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "arrow.turn.up.left")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Replying to message").font(.caption.bold())
                        Text(replyingToId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { self.replyingToId = nil } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 6)
            } else if let editingId {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "pencil")
                        .foregroundStyle(.tint)
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Editing message").font(.caption.bold())
                        Text(editingId).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button {
                        self.editingId = nil
                        self.text = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }.buttonStyle(.plain)
                }
                .padding(8)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 12)
                .padding(.top, 6)
            }

            HStack(alignment: .bottom, spacing: 8) {
                // Emoji button
                Button(action: onEmoji) {
                    Image(systemName: "face.smiling").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Insert emoji")

                // Attachment button
                Button { showFilePicker = true } label: {
                    Image(systemName: "paperclip").font(.title3)
                }
                .buttonStyle(.plain)
                .help("Attach file or image")

                // Multi-line text editor that sends on Enter, newline on Shift+Enter
                MultiLineInput(
                    text: $text,
                    placeholder: room.isEncrypted ? "🔒 E2EE…" : "Send a message…",
                    controller: controller,
                    onCommit: onSend,
                    onPasteData: onPasteData,
                    onCaret: { t, caret in handleEditorChange(text: t, caretUTF16: caret) },
                    autocompleteKeyHandler: handleAutocompleteKey,
                    onFileDrop: onAttach
                )
                .focused($focused)
                .onChange(of: text) { _, newValue in handleTextChange(newValue) }
                .padding(.vertical, 2)
                .padding(.horizontal, 4)
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(alignment: .topLeading) {
                    if let ac = autocomplete, !ac.entries.isEmpty {
                        AutocompletePopup(state: ac) { idx in confirm(idx) }
                            .frame(width: 340, height: popupHeight(ac))
                            .offset(y: -(popupHeight(ac) + 6))
                            .transition(.opacity)
                            .zIndex(1)
                    }
                }

                Button(action: onSend) {
                    Image(systemName: "paperplane.fill").font(.title3)
                }
                .buttonStyle(.borderedProminent)
                .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: [.command])
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .background(.background)
        .onAppear { focused = true }
        .task(id: room.id) { await room.loadMembers() }
        .onDisappear {
            stopTask?.cancel()
            Task { await room.setTyping(false) }
        }
        .fileImporter(
            isPresented: $showFilePicker,
            allowedContentTypes: [.item],
            allowsMultipleSelection: true
        ) { result in
            if case .success(let urls) = result {
                onAttach(urls)
            }
        }
        .onDrop(of: [.fileURL, .image], isTargeted: nil) { providers in
            handleDrop(providers)
        }
    }

    private func popupHeight(_ ac: AutocompleteState) -> CGFloat {
        let visible = min(ac.entries.count, 6)
        return CGFloat(visible) * 34 + 10
    }

    // MARK: - Drag & drop (covers the non-text areas of the composer)

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var handled = false
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                // Real files on disk (including image files from Finder).
                handled = true
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    if let url, url.isFileURL {
                        Task { @MainActor in onAttach([url]) }
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
                // Image dragged from an app/browser (no file URL). Materialize it
                // to a temp file so it's sent as a real image — images are files too.
                handled = true
                provider.loadFileRepresentation(forTypeIdentifier: UTType.image.identifier) { url, _ in
                    if let url {
                        let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                        let dst = FileManager.default.temporaryDirectory
                            .appendingPathComponent(UUID().uuidString)
                            .appendingPathExtension(ext)
                        do {
                            try FileManager.default.copyItem(at: url, to: dst)
                            Task { @MainActor in onAttach([dst]) }
                        } catch {
                            Task { @MainActor in
                                if let data = try? Data(contentsOf: url) {
                                    onPasteData(data, "dropped_image.\(ext)",
                                                UTType(filenameExtension: ext)?.preferredMIMEType ?? "image/png")
                                }
                            }
                        }
                        return
                    }
                    // Last resort: raw bytes off the provider.
                    provider.loadDataRepresentation(forTypeIdentifier: UTType.image.identifier) { data, _ in
                        guard let data else { return }
                        Task { @MainActor in onPasteData(data, "dropped_image.png", "image/png") }
                    }
                }
            }
        }
        return handled
    }

    // MARK: - Autocomplete

    private enum Detection {
        case mention(query: String, start: Int, end: Int)
        case emoji(query: String, start: Int, end: Int)
        case emojiComplete(name: String, start: Int, end: Int)
    }

    /// Inspect the whitespace-delimited token ending at the caret and decide whether
    /// it triggers a `@mention` list, a `:emoji:` search, or a completed `:name:`.
    private func detect(text: String, caretUTF16: Int) -> Detection? {
        let total = text.utf16.count
        let caretOff = max(0, min(caretUTF16, total))
        let caretIdx = String.Index(utf16Offset: caretOff, in: text)

        var startIdx = caretIdx
        while startIdx > text.startIndex {
            let prev = text.index(before: startIdx)
            let ch = text[prev]
            if ch == " " || ch == "\n" || ch == "\t" || ch == "\r" { break }
            startIdx = prev
        }
        if startIdx == caretIdx { return nil }

        let token = String(text[startIdx..<caretIdx])
        guard let first = token.first else { return nil }
        let startOff = startIdx.utf16Offset(in: text)

        if first == "@" {
            return .mention(query: String(token.dropFirst()), start: startOff, end: caretOff)
        }
        if first == ":" {
            if token.count >= 4, token.hasSuffix(":") {
                let inner = String(token.dropFirst().dropLast())
                if !inner.isEmpty, !inner.contains(":") {
                    return .emojiComplete(name: inner, start: startOff, end: caretOff)
                }
                return nil
            }
            let q = String(token.dropFirst())
            if q.count >= 2, !q.contains(":"),
               q.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" || $0 == "+" || $0 == "-" }) {
                return .emoji(query: q, start: startOff, end: caretOff)
            }
            return nil
        }
        return nil
    }

    private func handleEditorChange(text: String, caretUTF16: Int) {
        guard let det = detect(text: text, caretUTF16: caretUTF16) else {
            if autocomplete != nil { autocomplete = nil }
            return
        }
        switch det {
        case .mention(let q, let s, let e):
            let entries = mentionEntries(q)
            autocomplete = entries.isEmpty ? nil
                : AutocompleteState(kind: .mention, entries: entries, selected: 0, start: s, end: e)
        case .emoji(let q, let s, let e):
            let entries = emojiEntries(q)
            autocomplete = entries.isEmpty ? nil
                : AutocompleteState(kind: .emoji, entries: entries, selected: 0, start: s, end: e)
        case .emojiComplete(let name, let s, let e):
            if let ch = EmojiData.exact(name) {
                controller.replace(NSRange(location: s, length: max(0, e - s)), with: ch)
            }
            autocomplete = nil
        }
    }

    private func handleAutocompleteKey(_ k: AutocompleteKey) -> Bool {
        guard var ac = autocomplete, !ac.entries.isEmpty else { return false }
        switch k {
        case .up:
            ac.selected = (ac.selected - 1 + ac.entries.count) % ac.entries.count
            autocomplete = ac
            return true
        case .down:
            ac.selected = (ac.selected + 1) % ac.entries.count
            autocomplete = ac
            return true
        case .confirm:
            confirm(ac.selected)
            return true
        case .cancel:
            autocomplete = nil
            return true
        }
    }

    private func confirm(_ index: Int) {
        guard let ac = autocomplete, ac.entries.indices.contains(index) else { return }
        let entry = ac.entries[index]
        controller.replace(NSRange(location: ac.start, length: max(0, ac.end - ac.start)),
                           with: entry.insert)
        autocomplete = nil
    }

    private func memberName(_ m: RoomMember) -> String {
        if let d = m.displayName, !d.isEmpty { return d }
        let uid = m.userId
        if uid.hasPrefix("@"), let colon = uid.firstIndex(of: ":") {
            return String(uid[uid.index(after: uid.startIndex)..<colon])
        }
        return uid
    }

    private func mentionEntries(_ query: String) -> [ACEntry] {
        let q = query.lowercased()
        let joined = room.members.values.filter { $0.membership == .join }
        let scored: [(RoomMember, Int)] = joined.compactMap { m in
            let n = memberName(m).lowercased()
            let uid = m.userId.lowercased()
            if q.isEmpty { return (m, 0) }
            if n.hasPrefix(q) { return (m, 3) }
            if uid.dropFirst().hasPrefix(q) { return (m, 2) }
            if n.contains(q) || uid.contains(q) { return (m, 1) }
            return nil
        }
        let sorted = scored.sorted { a, b in
            if a.1 != b.1 { return a.1 > b.1 }
            return memberName(a.0).lowercased() < memberName(b.0).lowercased()
        }.prefix(50)
        return sorted.map { (m, _) in
            ACEntry(title: memberName(m), subtitle: m.userId,
                    avatarName: memberName(m), avatarMxc: m.avatarUrl,
                    glyph: nil, insert: "@\(memberName(m)) ")
        }
    }

    private func emojiEntries(_ query: String) -> [ACEntry] {
        EmojiData.search(query).map { e in
            ACEntry(title: ":\(e.name):", subtitle: nil, avatarName: nil,
                    avatarMxc: nil, glyph: e.char, insert: e.char)
        }
    }

    // MARK: - Typing notice

    private func handleTextChange(_ newValue: String) {
        let now = Date()
        if newValue.isEmpty {
            stopTask?.cancel()
            Task { await room.setTyping(false) }
            lastTypingSent = nil
            return
        }
        if lastTypingSent == nil || now.timeIntervalSince(lastTypingSent!) > 10 {
            Task { await room.setTyping(true) }
            lastTypingSent = now
        }
        stopTask?.cancel()
        stopTask = Task { [room] in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if !Task.isCancelled {
                await room.setTyping(false)
                await MainActor.run { lastTypingSent = nil }
            }
        }
    }
}

// MARK: - Autocomplete popup

private struct AutocompletePopup: View {
    let state: AutocompleteState
    let onPick: (Int) -> Void

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(state.entries.enumerated()), id: \.element.id) { idx, entry in
                        row(entry, selected: idx == state.selected)
                            .id(idx)
                            .contentShape(Rectangle())
                            .onTapGesture { onPick(idx) }
                    }
                }
            }
            .onChange(of: state.selected) { _, sel in
                withAnimation(.linear(duration: 0.08)) { proxy.scrollTo(sel, anchor: .center) }
            }
        }
        .background(.thickMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
    }

    @ViewBuilder
    private func row(_ entry: ACEntry, selected: Bool) -> some View {
        HStack(spacing: 8) {
            if let glyph = entry.glyph {
                Text(glyph).font(.system(size: 20)).frame(width: 26)
            } else {
                Avatar(name: entry.avatarName ?? entry.title, mxc: entry.avatarMxc, size: 24)
            }
            VStack(alignment: .leading, spacing: 0) {
                Text(entry.title).font(.callout).lineLimit(1)
                if let sub = entry.subtitle {
                    Text(sub).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(selected ? Color.accentColor.opacity(0.2) : Color.clear)
    }
}

// MARK: - Multi-line NSTextView wrapper (Enter → send, Shift+Enter → newline)

/// A lightweight NSTextView wrapper that intercepts Return to send and
/// Shift+Return to insert a newline, while supporting multi-line editing.
/// The view starts at single-line height and grows dynamically up to maxHeight.
struct MultiLineInput: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var controller: ComposerController
    var onCommit: () -> Void
    var onPasteData: ((Data, String, String) -> Void)?
    var onCaret: ((String, Int) -> Void)?
    var autocompleteKeyHandler: ((AutocompleteKey) -> Bool)?
    var onFileDrop: (([URL]) -> Void)?

    func makeNSView(context: Context) -> NSScrollView {
        let textView = InputTextView()
        textView.delegate = context.coordinator
        textView.commitHandler = onCommit
        textView.font = .systemFont(ofSize: 13)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.textColor = .labelColor
        textView.backgroundColor = .clear
        textView.textContainerInset = NSSize(width: 4, height: 3)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        textView.placeholderString = placeholder
        textView.pasteDataHandler = onPasteData
        textView.autocompleteKeyHandler = autocompleteKeyHandler
        textView.fileDropHandler = onFileDrop
        textView.imageDataDropHandler = onPasteData
        textView.registerForDraggedTypes([.fileURL, .png, .tiff, .fileContents])
        controller.attach(textView)

        let scroll = NSScrollView()
        scroll.documentView = textView
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        // Start at single-line height; recalcHeight will grow it as needed
        scroll.translatesAutoresizingMaskIntoConstraints = false
        scroll.heightAnchor.constraint(equalToConstant: 22).isActive = true

        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scroll.documentView as? InputTextView else { return }
        if textView.string != text {
            textView.string = text
            // Recalculate height after programmatic text changes (e.g. clearing after send)
            context.coordinator.recalcHeight(textView: textView, scrollView: scroll)
        }
        textView.commitHandler = onCommit
        textView.pasteDataHandler = onPasteData
        textView.autocompleteKeyHandler = autocompleteKeyHandler
        textView.fileDropHandler = onFileDrop
        textView.imageDataDropHandler = onPasteData
        textView.placeholderString = placeholder
        controller.attach(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    @MainActor
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MultiLineInput
        init(_ parent: MultiLineInput) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? InputTextView else { return }
            parent.text = tv.string
            recalcHeight(textView: tv, scrollView: tv.enclosingScrollView)
            parent.onCaret?(tv.string, tv.selectedRange().location)
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? InputTextView else { return }
            parent.onCaret?(tv.string, tv.selectedRange().location)
        }

        func recalcHeight(textView: NSTextView, scrollView: NSScrollView?) {
            guard let lm = textView.layoutManager,
                  let tc = textView.textContainer,
                  let scrollView else { return }
            lm.ensureLayout(for: tc)
            let used = lm.usedRect(for: tc)
            let inset = textView.textContainerInset
            let newHeight = min(max(used.height + inset.height * 2, 22), 150)
            // Update the scroll view's frame height constraint
            for constraint in scrollView.constraints where constraint.firstAttribute == .height {
                if constraint.constant != newHeight {
                    constraint.constant = newHeight
                }
                return
            }
            // If no height constraint yet, create one
            scrollView.translatesAutoresizingMaskIntoConstraints = false
            let hc = scrollView.heightAnchor.constraint(equalToConstant: newHeight)
            hc.isActive = true
        }
    }
}

/// NSTextView subclass that intercepts Return key events and file drops.
class InputTextView: NSTextView {
    var commitHandler: (() -> Void)?
    var pasteDataHandler: ((Data, String, String) -> Void)?  // data, filename, mime
    var autocompleteKeyHandler: ((AutocompleteKey) -> Bool)?
    var fileDropHandler: (([URL]) -> Void)?
    var imageDataDropHandler: ((Data, String, String) -> Void)?  // data, filename, mime
    var placeholderString: String? {
        didSet { needsDisplay = true }
    }

    override func keyDown(with event: NSEvent) {
        let shiftHeld = event.modifierFlags.contains(.shift)
        let optionHeld = event.modifierFlags.contains(.option)

        // While the autocomplete popup is open, route navigation keys to it.
        if let handler = autocompleteKeyHandler {
            switch event.keyCode {
            case 126: if handler(.up) { return }        // ↑
            case 125: if handler(.down) { return }      // ↓
            case 36:  if !shiftHeld, handler(.confirm) { return }  // Return
            case 48:  if handler(.confirm) { return }   // Tab
            case 53:  if handler(.cancel) { return }    // Esc
            default: break
            }
        }

        let isReturn = event.keyCode == 36
        if isReturn && !shiftHeld {
            commitHandler?()
            return
        }
        if isReturn && shiftHeld {
            insertNewline(nil)
            return
        }

        if optionHeld {
            let leftArrow: UInt16 = 123
            let rightArrow: UInt16 = 124
            let backspace: UInt16 = 51

            if event.keyCode == leftArrow {
                if shiftHeld { moveWordBackwardAndModifySelection(nil) }
                else { moveWordBackward(nil) }
                return
            } else if event.keyCode == rightArrow {
                if shiftHeld { moveWordForwardAndModifySelection(nil) }
                else { moveWordForward(nil) }
                return
            } else if event.keyCode == backspace {
                deleteWordBackward(nil)
                return
            }
        }

        super.keyDown(with: event)
    }

    // MARK: - File drag & drop

    private func canAcceptDrop(_ sender: NSDraggingInfo) -> Bool {
        !droppedFileURLs(sender).isEmpty || droppedImageData(sender) != nil
    }

    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender) ? .copy : super.draggingEntered(sender)
    }

    override func draggingUpdated(_ sender: NSDraggingInfo) -> NSDragOperation {
        canAcceptDrop(sender) ? .copy : super.draggingUpdated(sender)
    }

    override func prepareForDragOperation(_ sender: NSDraggingInfo) -> Bool {
        canAcceptDrop(sender) ? true : super.prepareForDragOperation(sender)
    }

    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        // File URLs (including image files dragged from Finder) → attach as files.
        let urls = droppedFileURLs(sender)
        if !urls.isEmpty {
            fileDropHandler?(urls)
            return true
        }
        // Raw image data dragged from an app/browser → send as an image file.
        if let img = droppedImageData(sender) {
            imageDataDropHandler?(img.data, img.filename, img.mime)
            return true
        }
        return super.performDragOperation(sender)
    }

    private func droppedFileURLs(_ sender: NSDraggingInfo) -> [URL] {
        let opts: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        let objs = sender.draggingPasteboard.readObjects(forClasses: [NSURL.self], options: opts)
        return (objs as? [URL]) ?? []
    }

    /// Image bytes when an image is dragged in *without* a backing file URL
    /// (e.g. dragged out of a browser or Photos). Normalized to PNG.
    private func droppedImageData(_ sender: NSDraggingInfo) -> (data: Data, filename: String, mime: String)? {
        let pb = sender.draggingPasteboard
        if let png = pb.data(forType: .png) {
            return (png, "dropped_image.png", "image/png")
        }
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "dropped_image.png", "image/png")
        }
        if let img = NSImage(pasteboard: pb),
           let tiff = img.tiffRepresentation,
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return (png, "dropped_image.png", "image/png")
        }
        return nil
    }

    override func paste(_ sender: Any?) {
        let pb = NSPasteboard.general
        // Check for file URLs on pasteboard (images, documents, etc.)
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [
            .urlReadingFileURLsOnly: true
        ]) as? [URL], !urls.isEmpty {
            for url in urls {
                if let data = try? Data(contentsOf: url) {
                    let ext = url.pathExtension.lowercased()
                    let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
                    pasteDataHandler?(data, url.lastPathComponent, mime)
                }
            }
            return
        }
        // Check for TIFF (screenshot paste) or PNG data directly
        if let tiffData = pb.data(forType: .tiff),
           let bitmapRep = NSBitmapImageRep(data: tiffData),
           let pngData = bitmapRep.representation(using: .png, properties: [:]) {
            pasteDataHandler?(pngData, "pasted_image.png", "image/png")
            return
        }
        if let pngData = pb.data(forType: .png) {
            pasteDataHandler?(pngData, "pasted_image.png", "image/png")
            return
        }
        // Default: paste text
        super.paste(sender)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        // Draw placeholder when empty
        if string.isEmpty, let placeholder = placeholderString {
            let attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: font ?? NSFont.systemFont(ofSize: 13),
            ]
            let inset = textContainerInset
            let rect = NSRect(
                x: inset.width + 5,
                y: inset.height,
                width: bounds.width - inset.width * 2 - 5,
                height: bounds.height - inset.height * 2
            )
            NSString(string: placeholder).draw(in: rect, withAttributes: attrs)
        }
    }
}
