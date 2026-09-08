import SwiftUI
import SpatialApple

struct SpatialDemoView: View {
    @Bindable var session: DemoSessionModel
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        ZStack {
            NativeARView(controller: session.controller, pointingEnabled: $session.isPointingEnabled)
                .ignoresSafeArea()

            LinearGradient(
                colors: [.black.opacity(0.62), .clear, .black.opacity(0.88)],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            PointingFeedbackOverlay(
                update: session.controller.pointingUpdate,
                isEnabled: session.isPointingEnabled
            )

            VStack(spacing: 0) {
                if horizontalSizeClass == .compact {
                    compactTopBar
                } else {
                    topBar
                }
                if let activity = session.controller.activity {
                    statusPill(activity, tint: .orange)
                } else if let explanation = session.controller.lastExplanation {
                    statusPill(explanation, tint: .cyan)
                } else if let error = session.controller.lastError {
                    statusPill(error, tint: .red)
                }
                Spacer(minLength: 12)
                bottomControls
            }
            .padding(.horizontal, 22)
            .padding(.top, 16)
            .padding(.bottom, 18)
        }
        .sheet(isPresented: $session.isSettingsPresented) {
            ConnectionSettingsView(session: session)
                .presentationDetents([.medium])
        }
        .alert("Integration unavailable", isPresented: Binding(
            get: { session.runtimeUnavailableReason != nil },
            set: { if !$0 { session.runtimeUnavailableReason = nil } }
        )) {
            Button("OK", role: .cancel) { session.runtimeUnavailableReason = nil }
        } message: {
            Text(session.runtimeUnavailableReason ?? "")
        }
    }

    private func statusPill(_ text: String, tint: Color) -> some View {
        Text(text)
            .font(.system(size: 13, weight: .medium, design: .rounded))
            .foregroundStyle(.white.opacity(0.9))
            .lineLimit(2)
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14).stroke(tint.opacity(0.5)))
            .frame(maxWidth: 520)
            .accessibilityIdentifier("runtime-message")
    }

    private var topBar: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ASTRA SPATIAL")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.white.opacity(0.78))
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .foregroundStyle(.white.opacity(0.86))
                }
                .accessibilityIdentifier("runtime-status")
            }
            Spacer()
            HStack(spacing: 10) {
                Text(session.selectionLabel)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .accessibilityIdentifier("selected-part-label")
                Button {
                    session.isSettingsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.34), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connection settings")
                    .accessibilityIdentifier("connection-settings")
                Button {
                    session.loadRack()
                } label: {
                    Label("Load rack", systemImage: "cube.transparent")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .padding(.horizontal, 12)
                        .frame(height: 42)
                        .background(.black.opacity(0.34), in: Capsule())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("load-rack")
            }
        }
        .foregroundStyle(.white)
    }

    private var compactTopBar: some View {
        VStack(spacing: 9) {
            HStack(spacing: 10) {
                Text("ASTRA SPATIAL")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .tracking(2.1)
                    .foregroundStyle(.white.opacity(0.78))
                Spacer(minLength: 8)
                Button {
                    session.isSettingsPresented = true
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.34), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Connection settings")
                .accessibilityIdentifier("connection-settings")
                Button {
                    session.loadRack()
                } label: {
                    Image(systemName: "cube.transparent")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 42, height: 42)
                        .background(.black.opacity(0.34), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Load rack")
                .accessibilityIdentifier("load-rack")
            }

            HStack(alignment: .firstTextBaseline, spacing: 10) {
                HStack(spacing: 7) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusText)
                        .font(.system(size: 13, weight: .medium, design: .rounded))
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                }
                .accessibilityIdentifier("runtime-status")
                Spacer(minLength: 8)
                Text(session.selectionLabel)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .accessibilityIdentifier("selected-part-label")
            }
        }
        .foregroundStyle(.white)
    }

    private var bottomControls: some View {
        VStack(spacing: 12) {
            HStack(spacing: 8) {
                Text(surfaceLabel)
                    .font(.system(size: 10, weight: .semibold, design: .monospaced))
                    .tracking(1.1)
                    .foregroundStyle(.white.opacity(0.53))
                Spacer()
                Button(session.isPointingEnabled ? "Hand · On" : "Hand · Off") {
                    session.togglePointing()
                }
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .buttonStyle(.bordered)
                .tint(.white.opacity(0.75))
                .foregroundStyle(session.isPointingEnabled ? .green : .primary)
                .accessibilityIdentifier("hand-mode")
            }

            if session.isPointingEnabled {
                Text(pointingHint)
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(.white.opacity(0.68))
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityIdentifier("pointing-hint")
            }

            HStack(alignment: .bottom, spacing: 12) {
                TextField("Ask Astra to explain or reshape the scene…", text: $session.composerText, axis: .vertical)
                    .lineLimit(1...3)
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .padding(.horizontal, 16)
                    .padding(.vertical, 13)
                    .background(.black.opacity(0.56), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 18).stroke(.white.opacity(0.14)))
                    .accessibilityIdentifier("text-composer")
                Button {
                    session.requestMicrophone()
                } label: {
                    Image(systemName: session.isVoiceActive ? "stop.fill" : "mic.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .frame(width: 48, height: 48)
                        .background(session.isVoiceActive ? Color.orange.opacity(0.8) : Color.white.opacity(0.13), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(session.isVoiceActive ? "Stop voice input" : "Start voice input")
                .accessibilityIdentifier("microphone-button")
                Button {
                    session.sendComposer()
                } label: {
                    Image(systemName: "arrow.up")
                        .font(.system(size: 17, weight: .bold))
                        .frame(width: 48, height: 48)
                        .background(session.canSend ? Color.white : Color.white.opacity(0.12), in: Circle())
                        .foregroundStyle(session.canSend ? .black : .white.opacity(0.34))
                }
                .buttonStyle(.plain)
                .disabled(!session.canSend)
                .accessibilityLabel("Send request")
                .accessibilityIdentifier("send-request")
            }

            HStack(spacing: 10) {
                Button {
                    session.stop()
                } label: {
                    Label("Stop", systemImage: "stop.fill")
                }
                .accessibilityIdentifier("stop-button")
                Button {
                    session.undo()
                } label: {
                    Label("Undo", systemImage: "arrow.uturn.backward")
                }
                .accessibilityIdentifier("undo-button")
                Spacer()
                Text(session.isVoiceActive ? session.voiceStatusText : "Ask Astra to explain or reshape the scene")
                    .font(.system(size: 10, weight: .regular, design: .rounded))
                    .foregroundStyle(.white.opacity(0.45))
            }
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.8))
        }
    }

    private var statusText: String {
        if session.isConnected { return "Connected · live scene" }
        if session.isConnecting { return "Connecting…" }
        return "Offline · preview available"
    }

    private var statusColor: Color {
        if session.isConnected { return .green }
        if session.isConnecting { return .orange }
        return .white.opacity(0.45)
    }

    private var surfaceLabel: String {
        #if targetEnvironment(simulator)
        return "SIMULATOR PREVIEW · NON-AR SURFACE"
        #else
        return "AR CAMERA · TAP TO PLACE"
        #endif
    }

    private var pointingHint: String {
        guard let update = session.controller.pointingUpdate else {
            return "Show your hand"
        }
        guard update.cursor != nil else {
            return "Show your hand"
        }
        if let stableHover = update.stableHover {
            return session.semanticName(for: stableHover.target.nodeID)
        }
        if let hover = update.hover {
            return "Aim at \(session.semanticName(for: hover.target.nodeID))"
        }
        return "Aim at a part"
    }
}

private struct PointingFeedbackOverlay: View {
    let update: PointingResolverUpdate?
    let isEnabled: Bool

    var body: some View {
        GeometryReader { _ in
            if isEnabled, let cursor = update?.cursor {
                let isStable = update?.stableHover != nil
                ZStack {
                    Circle()
                        .stroke(isStable ? Color.green : Color.orange, lineWidth: 2)
                        .frame(width: 42, height: 42)
                    Circle()
                        .fill(isStable ? Color.green : Color.orange)
                        .frame(width: 6, height: 6)
                }
                .position(x: cursor.point.x, y: cursor.point.y)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct ConnectionSettingsView: View {
    @Bindable var session: DemoSessionModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section("Session backend") {
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
                    Button("Disconnect", role: .destructive) {
                        session.controller.disconnect()
                        dismiss()
                    }
                    .accessibilityIdentifier("disconnect-button")
                }
                Section {
                    Text("The simulator uses a touch-driven non-AR preview. Camera tracking and hand pointing require a supported physical device and the native runtime integration.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Connection")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
