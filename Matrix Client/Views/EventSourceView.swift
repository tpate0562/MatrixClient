import SwiftUI
import AppKit
import MatrixRustSDK

struct EventSourceView: View {
    let item: TimelineItem
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading) {
                    Text("Event Source").font(.headline)
                    Text(item.uniqueId().id).font(.caption.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Copy") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(item.fmtDebug(), forType: .string)
                }
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            Divider()
            ScrollView {
                Text(item.fmtDebug())
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        }
        .frame(width: 720, height: 600)
    }
}
