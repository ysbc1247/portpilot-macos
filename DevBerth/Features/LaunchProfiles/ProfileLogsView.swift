import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct ProfileLogsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let profileID: UUID
    let profileName: String
    @State private var entries: [ServiceLogEntry] = []
    @State private var searchText = ""
    @State private var isPaused = false
    @State private var exportsDocument: LogTextDocument?
    @State private var displayedRevision: UInt64?

    private var filtered: [ServiceLogEntry] {
        guard !searchText.isEmpty else { return entries }
        return entries.filter { $0.message.localizedCaseInsensitiveContains(searchText) }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Logs — \(profileName)").font(.headline)
                Spacer()
                TextField("Search", text: $searchText).textFieldStyle(.roundedBorder).frame(width: 200)
                Button(isPaused ? "Resume" : "Pause", systemImage: isPaused ? "play" : "pause") { isPaused.toggle() }
                Button("Clear", systemImage: "trash") { Task { await model.logBuffer.clear(profileID: profileID); entries = [] } }
                Button("Copy", systemImage: "doc.on.doc") { copyLogs() }.disabled(filtered.isEmpty)
                Button("Export", systemImage: "square.and.arrow.up") { exportsDocument = LogTextDocument(text: rendered(filtered)) }
                    .disabled(filtered.isEmpty)
                Button("Close", systemImage: "xmark") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()
            Divider()
            if filtered.isEmpty {
                EmptyStateView(symbol: "text.alignleft", title: "No log output", message: "stdout, stderr, and lifecycle messages will stream here while DevBerth runs this managed service.")
            } else {
                ScrollViewReader { proxy in
                    List(filtered) { entry in
                        HStack(alignment: .firstTextBaseline, spacing: DevBerthSpacing.small) {
                            Text(entry.timestamp, format: .dateTime.hour().minute().second())
                                .foregroundStyle(.tertiary).monospacedDigit()
                            Text(entry.stream == .standardError ? "ERR" : entry.stream == .standardOutput ? "OUT" : "SYS")
                                .foregroundStyle(entry.stream == .standardError ? .red : .secondary)
                                .font(.caption.bold()).frame(width: 28)
                            Text(entry.message).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        }
                        .id(entry.id)
                    }
                    .onChange(of: entries.count) { _, _ in if let last = entries.last { proxy.scrollTo(last.id, anchor: .bottom) } }
                }
            }
        }
        .frame(minWidth: 760, minHeight: 480)
        .task {
            while !Task.isCancelled {
                if !isPaused {
                    let revision = await model.logBuffer.revision(for: profileID)
                    if displayedRevision != revision {
                        entries = await model.logBuffer.entries(for: profileID)
                        displayedRevision = await model.logBuffer.revision(for: profileID)
                    }
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        .fileExporter(
            isPresented: Binding(get: { exportsDocument != nil }, set: { if !$0 { exportsDocument = nil } }),
            document: exportsDocument,
            contentType: .plainText,
            defaultFilename: "\(profileName)-logs.txt"
        ) { _ in exportsDocument = nil }
        .onExitCommand { dismiss() }
    }

    private func rendered(_ values: [ServiceLogEntry]) -> String {
        values.map { "[\($0.timestamp.formatted(.iso8601))] [\($0.stream.rawValue)] \($0.message)" }.joined(separator: "\n")
    }

    private func copyLogs() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rendered(filtered), forType: .string)
    }
}

struct LogTextDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.plainText] }
    let text: String
    init(text: String) { self.text = text }
    init(configuration: ReadConfiguration) throws {
        text = String(decoding: configuration.file.regularFileContents ?? Data(), as: UTF8.self)
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: Data(text.utf8))
    }
}
