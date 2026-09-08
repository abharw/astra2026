import SwiftUI

struct ConnectionSettingsView: View {
    @Bindable var session: DemoSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Connection") {
                    LabeledContent("Status", value: connectionLabel)
                    TextField("Backend URL", text: $session.backendURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .accessibilityIdentifier("backend-url")
                    SecureField("Session access token (optional)", text: $session.sessionAuthToken)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("session-token")
                    Button("Connect") {
                        session.connect()
                        dismiss()
                    }
                    .accessibilityIdentifier("connect-button")
                    if session.isConnected || session.isConnecting {
                        Button("Disconnect", role: .destructive) {
                            session.disconnect()
                            dismiss()
                        }
                        .accessibilityIdentifier("disconnect-button")
                    }
                }
                Section("Scene") {
                    Button("Load server rack") {
                        session.loadRack()
                        dismiss()
                    }
                    Button("Load procedural example") {
                        session.loadProceduralExample()
                        dismiss()
                    }
                }
                Section {
                    NavigationLink("Diagnostics") {
                        DiagnosticsView(session: session)
                    }
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private var connectionLabel: String {
        if session.isConnected { return "Connected" }
        if session.isConnecting { return "Connecting" }
        return "Offline"
    }
}
