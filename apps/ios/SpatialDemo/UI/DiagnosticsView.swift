import SwiftUI
import SpatialApple

/// A local view of the same events collected from the device over USB.
/// It stays usable when the session backend cannot be reached.
struct DiagnosticsView: View {
    @Bindable var session: DemoSessionModel
    @State private var events: [DiagnosticEvent] = []
    @State private var exportURL: URL?
    @State private var exportError: String?

    var body: some View {
        List {
            Section("Current state") {
                LabeledContent("Scene connection", value: session.connectionLabel)
                LabeledContent("Conversation", value: session.voiceStatusText)
                LabeledContent("Scene revision", value: String(session.controller.acceptedScene.revision))
                if let stage = session.controller.activity { LabeledContent("Scene stage", value: stage) }
                if let error = session.lastError { Text(error).foregroundStyle(.red) }
                if let error = exportError { Text(error).foregroundStyle(.red) }
            }
            Section {
                Button("Prepare log export") {
                    do {
                        exportURL = try DiagnosticsLog.shared.exportSnapshot()
                        exportError = DiagnosticsLog.shared.lastPersistenceError
                    } catch {
                        exportError = error.localizedDescription
                    }
                }
                if let exportURL {
                    ShareLink("Share diagnostics", item: exportURL)
                }
            } footer: {
                Text("Local logs contain stages, IDs, timings, and error codes. Request text, microphone audio, and credentials are excluded. The newest events appear first.")
            }
            Section("Recent events") {
                ForEach(events.reversed()) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        HStack(alignment: .firstTextBaseline) {
                            Text(event.event).font(.system(.footnote, design: .monospaced).weight(.semibold))
                                .foregroundStyle(event.level == .error ? Color.red : .primary)
                            Spacer()
                            Text("#\(event.sequence)").foregroundStyle(.secondary)
                        }
                        Text("\(event.timestamp) · \(event.component)")
                            .font(.caption2).foregroundStyle(.secondary)
                        if let id = event.correlationID {
                            Text(id).font(.system(.caption2, design: .monospaced)).textSelection(.enabled)
                        }
                        if !event.fields.isEmpty {
                            Text(event.fields.keys.sorted().map { "\($0): \(event.fields[$0] ?? "")" }.joined(separator: " · "))
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 3)
                }
            }
        }
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                events = DiagnosticsLog.shared.recentEvents()
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }
}
