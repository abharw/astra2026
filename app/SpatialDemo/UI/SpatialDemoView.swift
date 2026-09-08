import SwiftUI
import SpatialApple

struct SpatialDemoView: View {
    @Bindable var session: DemoSessionModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var isComposerFocused: Bool
    @State private var isResponsePresented = false
    @State private var isIllustrationPresented = false

    var body: some View {
        ZStack {
            // Keep camera and ring in ARView's full-screen viewport. Only the
            // chrome avoids the keyboard; resizing the camera moves the ring.
            NativeARView(
                controller: session.controller,
                pointingEnabled: $session.isPointingEnabled,
                isActive: isCameraInteractionActive
            )
            .ignoresSafeArea()

            LinearGradient(
                stops: [
                    .init(color: .black.opacity(0.35), location: 0),
                    .init(color: .clear, location: 0.22),
                    .init(color: .clear, location: 0.65),
                    .init(color: .black.opacity(0.4), location: 1),
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            PointingFeedbackOverlay(
                update: session.controller.pointingUpdate,
                isEnabled: session.isPointingEnabled && isCameraInteractionActive
            )

            VStack(spacing: 0) {
                if !isCompactLandscape || !isComposerFocused {
                    topBar
                }
                Spacer(minLength: 8)
                conversationDock
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
            .padding(.bottom, 8)
        }
        .tint(.white)
        .preferredColorScheme(.dark)
        .sheet(isPresented: $session.isSettingsPresented) {
            ConnectionSettingsView(session: session)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $isResponsePresented) {
            AssistantResponseSheet(text: session.assistantText ?? "")
        }
        .sheet(isPresented: $isIllustrationPresented) {
            IllustrationSheet(controller: session.controller)
        }
        .alert("Astra", isPresented: Binding(
            get: { session.runtimeUnavailableReason != nil },
            set: { if !$0 { session.runtimeUnavailableReason = nil } }
        )) {
            Button("OK", role: .cancel) { session.runtimeUnavailableReason = nil }
        } message: {
            Text(session.runtimeUnavailableReason ?? "")
        }
        .onChange(of: session.lastSubmittedRequestID) { _, current in
            // Editing to an empty draft must not dismiss the keyboard.
            if current != nil, session.composerText.isEmpty {
                isComposerFocused = false
            }
        }
        .onChange(of: session.presentationPhase, initial: true) { _, _ in
            recordPresentation()
        }
        .onChange(of: isComposerFocused) { _, _ in
            recordPresentation()
        }
        .onChange(of: session.controller.illustration?.jobID) { _, jobID in
            if jobID == nil { isIllustrationPresented = false }
        }
    }

    private var topBar: some View {
        HStack {
            Button {
                isComposerFocused = false
                session.isSettingsPresented = true
            } label: {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .accessibilityLabel("Settings")
            .accessibilityIdentifier("connection-settings")
            Spacer()
            Text("Astra")
                .font(.headline)
                .foregroundStyle(.white)
            Spacer()
            Button {
                isComposerFocused = false
                session.loadRack()
            } label: {
                Image(systemName: "cube")
                    .font(.system(size: 19, weight: .medium))
                    .frame(width: 44, height: 44)
                    .background(.black.opacity(0.62), in: Circle())
            }
            .accessibilityLabel("Load server rack")
            .accessibilityIdentifier("load-rack")
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
    }

    private var conversationDock: some View {
        VStack(alignment: .leading, spacing: 10) {
            if session.controller.selection?.primaryNodeID != nil,
               !isCompactLandscape || !isComposerFocused {
                Label(session.selectionLabel, systemImage: "scope")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.78), in: Capsule())
                    .accessibilityLabel("Selected: \(session.selectionLabel)")
                    .accessibilityIdentifier("selected-part-label")
            }
            ConversationFeedback(
                phase: session.presentationPhase,
                response: showsResponse ? session.assistantText : nil,
                responseLineLimit: isCompactLandscape || isComposerFocused ? 2 : 4,
                retry: session.retryLastAction,
                openResponse: { isResponsePresented = true }
            )
            if let illustration = session.controller.illustration {
                IllustrationPanel(
                    illustration: illustration,
                    isCompact: isCompactLandscape || isComposerFocused,
                    cancel: session.controller.cancelIllustration,
                    retry: session.controller.retryIllustration,
                    dismiss: session.controller.dismissIllustration,
                    open: {
                        isComposerFocused = false
                        isIllustrationPresented = true
                    }
                )
            }
            ConversationComposer(
                text: $session.composerText,
                isFocused: $isComposerFocused,
                isMicrophoneActive: session.isVoiceActive,
                canSend: session.canSend,
                lineLimit: isCompactLandscape ? 2 : 4,
                send: session.sendComposer,
                toggleMicrophone: {
                    isComposerFocused = false
                    session.requestMicrophone()
                }
            )
        }
        .frame(maxWidth: 620)
        .frame(maxWidth: .infinity)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.18), value: session.presentationPhase)
    }

    private var isCompactLandscape: Bool { verticalSizeClass == .compact }

    private var isCameraInteractionActive: Bool {
        scenePhase == .active && !session.isSettingsPresented && !isResponsePresented && !isIllustrationPresented
    }

    private var showsResponse: Bool {
        // Leave room for the image action and composer above a landscape keyboard.
        if isCompactLandscape && isComposerFocused && session.controller.illustration != nil {
            return false
        }
        switch session.presentationPhase {
        case .ready, .listening, .responding: return true
        default: return false
        }
    }

    private func recordPresentation() {
        let responseLength = session.assistantText?.count ?? 0
        DiagnosticsLog.shared.record(
            "presentation.changed",
            component: "app.ui",
            correlationID: session.lastSubmittedRequestID,
            fields: [
                "phase": session.presentationPhase.label,
                "composer_focused": String(isComposerFocused),
                "response_characters": String(responseLength),
                "response_visible": String(showsResponse && responseLength > 0),
            ]
        )
    }
}

private struct PointingFeedbackOverlay: View {
    let update: PointingResolverUpdate?
    let isEnabled: Bool

    var body: some View {
        GeometryReader { _ in
            if isEnabled, let cursor = update?.cursor {
                let hasTarget = update?.stableHover != nil
                ZStack {
                    Circle()
                        .stroke(hasTarget ? Color.green : Color.white.opacity(0.85), lineWidth: 2)
                        .frame(width: 36, height: 36)
                    Circle()
                        .fill(hasTarget ? Color.green : Color.white)
                        .frame(width: 5, height: 5)
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
