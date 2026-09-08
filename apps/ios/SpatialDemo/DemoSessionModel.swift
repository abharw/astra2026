import Foundation
import Observation
import SpatialCore
import SpatialApple

/// Composes conversation and scene execution; the executors know no rack-specific behavior.
@MainActor
@Observable
final class DemoSessionModel {
    let controller = SceneController()

    @ObservationIgnored private var speechLocks: [String: PointingSpeechLock] = [:]
    @ObservationIgnored private var latestSpeechLock: PointingSpeechLock?
    @ObservationIgnored private var turnSceneIDs: [String: String] = [:]
    @ObservationIgnored private var connectionTask: Task<Bool, Never>?
    @ObservationIgnored private var connectionAttempt = UUID()
    @ObservationIgnored private var connectionConfiguration: BackendConnectionConfiguration?
    @ObservationIgnored private var submissionTask: Task<Void, Never>?
    @ObservationIgnored private var submissionAttempt = UUID()
    @ObservationIgnored private var microphoneTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneAttempt = UUID()
    @ObservationIgnored private var assetLoadTask: Task<Void, Never>?
    @ObservationIgnored private var assetLoadAttempt = UUID()
    @ObservationIgnored private var retryAction: RetryAction = .connect
    @ObservationIgnored private var failedSubmission: TextSubmission?
    @ObservationIgnored private var isAppActive = false

    private struct TextSubmission {
        let text: String
        let sceneID: String
        let nodeIDs: [String]
    }

    private enum RetryAction { case connect, sendText, microphone, loadRack }

    @ObservationIgnored private lazy var conversation = RealtimeSession(
        selectionProvider: { [weak self] in
            guard let self else { return nil }
            self.latestSpeechLock = nil
            if self.isPointingEnabled,
               let cursor = self.controller.pointingUpdate?.cursor,
               ProcessInfo.processInfo.systemUptime - cursor.timestamp <= 0.35 {
                guard let lock = self.controller.beginSpeech() else {
                    // Uncertain pointing must not disable ordinary conversation or
                    // silently bind speech to an older selected component.
                    DiagnosticsLog.shared.record("speech.pointing_unresolved", component: "app")
                    return []
                }
                self.latestSpeechLock = lock
                return [lock.selection.nodeID]
            }
            return self.controller.selection?.nodeIDs ?? []
        },
        onSpeechStarted: { [weak self] binding in
            guard let self else { return }
            self.turnSceneIDs[binding.requestID] = self.controller.acceptedScene.sceneId
            self.interactionError = nil
            if let lock = self.latestSpeechLock {
                self.speechLocks[binding.requestID] = lock
                self.latestSpeechLock = nil
            }
        },
        onSpeechDiscarded: { [weak self] binding in
            guard let self else { return }
            if let lock = self.speechLocks.removeValue(forKey: binding.requestID) {
                self.controller.endSpeech(lock)
            }
            self.turnSceneIDs.removeValue(forKey: binding.requestID)
        },
        executeScene: { [weak self] request in
            guard let self else {
                return RealtimeSceneToolResult(status: "cancelled", requestID: request.requestID, error: "The app session ended.")
            }
            return await self.executeSceneTool(request)
        }
    )

    init() {
        let configuration = SessionConfigurationStore().load()
        backendURL = configuration.backendURL
        sessionAuthToken = configuration.token
        DiagnosticsLog.shared.record("app.started", component: "app", fields: [
            "version": Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development",
            "build": Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development",
        ])
    }

    var backendURL: String
    var sessionAuthToken: String
    var composerText = ""
    var isSettingsPresented = false
    #if targetEnvironment(simulator)
    var isPointingEnabled = false
    #else
    var isPointingEnabled = true
    #endif
    var runtimeUnavailableReason: String?
    private var interactionError: String?
    private(set) var assetLoadStatus: String?
    private(set) var assetLoadPhase: ImportedAssetLoadPhase?
    private(set) var loadedAssetName: String?
    private(set) var isEstablishingConnection = false
    private(set) var isSubmitting = false
    private(set) var isRequestingMicrophone = false
    private(set) var lastSubmittedRequestID: String?

    var connectionLabel: String { String(describing: controller.connectionState) }
    var voiceStatusText: String { conversation.statusText }
    var isVoiceActive: Bool { conversation.isMicrophoneEnabled }
    var isConnected: Bool { controller.connectionState == .connected && conversation.isConnected }
    var isConnecting: Bool { isEstablishingConnection || controller.connectionState == .connecting || conversation.isConnecting }
    var canSend: Bool { !isSubmitting && !composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    var lastError: String? {
        if let interactionError { return interactionError }
        if let error = conversation.lastError {
            if error.localizedCaseInsensitiveContains("microphone access is denied") {
                return "Allow microphone access in iOS Settings to use voice."
            }
            if error.localizedCaseInsensitiveContains("microphone") {
                return "The microphone is unavailable. Please retry."
            }
            return "Astra couldn’t finish that response. Please retry."
        }
        if controller.lastError != nil { return "Astra couldn’t update the scene. Please retry." }
        return nil
    }
    var assistantText: String? {
        conversation.lastAssistantText.isEmpty ? controller.lastExplanation : conversation.lastAssistantText
    }
    var activityText: String? {
        if let assetLoadStatus { return assetLoadStatus }
        if let activity = controller.activity { return activity }
        switch conversation.activity {
        case .fetchingCredential, .connecting, .requestingPermission, .waitingForAstra, .delivering, .reconfiguringAudio:
            return conversation.statusText
        default: return nil
        }
    }

    var presentationPhase: DemoPresentationPhase {
        if isConnecting { return .connecting }
        if let assetLoadPhase {
            switch assetLoadPhase {
            case .downloading: return .downloading
            case .checkingCache, .loadingEntities, .preparingParts: return .loadingAsset
            case .verifying: return .processing
            case .installing: return .constructing
            }
        }
        if assetLoadStatus != nil { return .loadingAsset }
        if let activity = controller.activity {
            switch activity {
            case "thinking", "awaiting response": return .thinking
            case "generating", "repairing_proposal": return .generating
            case "awaiting_installation", "installing": return .constructing
            case "processing": return .processing
            default: return .processing
            }
        }
        if isSubmitting || isRequestingMicrophone { return .processing }
        if let lastError { return .failed(lastError) }
        switch conversation.activity {
        case .fetchingCredential, .connecting: return .connecting
        case .listening: return .listening
        case .waitingForAstra: return .thinking
        case .delivering: return .responding
        case .requestingPermission, .reconfiguringAudio: return .processing
        default: return .ready
        }
    }

    var selectionLabel: String {
        guard let selection = controller.selection, let primary = selection.primaryNodeID else { return "Nothing selected" }
        let name = semanticName(for: primary)
        let additional = max(selection.nodeIDs.count - 1, 0)
        return additional == 0 ? name : "\(name) + \(additional)"
    }

    func semanticName(for nodeID: String) -> String {
        controller.acceptedScene.document.nodes.first(where: { $0.nodeId == nodeID })?.semantic.name ?? nodeID
    }

    func togglePointing() {
        #if targetEnvironment(simulator)
        runtimeUnavailableReason = "Hand pointing requires a physical iPhone or iPad camera. Touch selection remains available in the simulator."
        #else
        isPointingEnabled.toggle()
        DiagnosticsLog.shared.record("pointing.toggled", component: "app", fields: ["enabled": String(isPointingEnabled)])
        #endif
    }

    func loadRack() {
        cancelPendingInput()
        assetLoadTask?.cancel()
        conversation.interrupt()
        turnSceneIDs.removeAll()
        interactionError = nil
        retryAction = .loadRack
        let attempt = UUID()
        assetLoadAttempt = attempt
        assetLoadStatus = "Preparing the Blender rack…"
        assetLoadPhase = nil
        DiagnosticsLog.shared.record("import.started", component: "app", correlationID: attempt.uuidString,
                                     fields: ["catalog": "app-catalog", "source": "Akeil/051c9d9/faithful-v2"])
        assetLoadTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.assetLoadAttempt == attempt {
                    self.assetLoadStatus = nil
                    self.assetLoadPhase = nil
                    self.assetLoadTask = nil
                }
            }
            do {
                guard let catalogURL = Bundle.main.url(forResource: "app-catalog", withExtension: "json") else {
                    throw ImportedAssetError.invalidDescriptor("the source catalog is not bundled")
                }
                var descriptor = try JSONDecoder().decode(ImportedAssetDescriptor.self, from: Data(contentsOf: catalogURL))
                // Bundle resolution is a host concern; the SDK receives an approved file or network URL.
                if descriptor.sourceURL.scheme == "bundle" {
                    let name = descriptor.sourceURL.deletingPathExtension().lastPathComponent
                    guard let file = Bundle.main.url(forResource: name, withExtension: "usdz") else {
                        throw ImportedAssetError.invalidDescriptor("the approved asset is not bundled")
                    }
                    descriptor.sourceURL = file
                }
                let report = try await self.controller.loadImportedAsset(
                    descriptor, rootNodeID: "rack01", scale: 0.6 / 2.21,
                    progress: { [weak self] phase in
                        guard let self, self.assetLoadAttempt == attempt else { return }
                        self.assetLoadPhase = phase
                        DiagnosticsLog.shared.record("import.phase", component: "app", correlationID: attempt.uuidString,
                                                     fields: ["phase": phase.rawValue])
                        switch phase {
                        case .checkingCache: self.assetLoadStatus = "Checking the Blender asset cache…"
                        case .downloading: self.assetLoadStatus = "Downloading the asset…"
                        case .verifying: self.assetLoadStatus = "Verifying the source asset…"
                        case .loadingEntities: self.assetLoadStatus = "Loading the USDZ hierarchy…"
                        case .preparingParts: self.assetLoadStatus = "Preparing 18 selectable servers…"
                        case .installing: self.assetLoadStatus = "Installing the Blender rack…"
                        }
                    }
                )
                guard !Task.isCancelled, self.assetLoadAttempt == attempt else { return }
                self.loadedAssetName = "Akeil · Open Rack V2 · 18 servers"
                DiagnosticsLog.shared.record("import.finished", component: "app", correlationID: attempt.uuidString, fields: [
                    "asset_id": report.assetID, "source": "Akeil/051c9d9",
                    "seconds": String(report.loadDurationSeconds), "bytes": String(report.byteCount),
                ])
            } catch {
                guard !Task.isCancelled, self.assetLoadAttempt == attempt else { return }
                self.interactionError = "Couldn’t load the rack. Please retry."
                self.retryAction = .loadRack
                DiagnosticsLog.shared.record("import.failed", component: "app", level: .error, fields: ["error": error.localizedDescription])
            }
        }
    }

    func loadProceduralExample() {
        cancelPendingInput()
        assetLoadAttempt = UUID()
        assetLoadTask?.cancel()
        assetLoadTask = nil
        assetLoadStatus = nil
        assetLoadPhase = nil
        conversation.interrupt()
        turnSceneIDs.removeAll()
        guard let url = Bundle.main.url(forResource: "scene", withExtension: "json") else {
            runtimeUnavailableReason = "The authored rack scene is not bundled in this build."
            return
        }
        do {
            let document = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: url))
            try controller.loadScene(document)
            loadedAssetName = "Procedural hardware example"
            interactionError = nil
            DiagnosticsLog.shared.record("example.loaded", component: "app", fields: ["node_count": String(document.nodes.count)])
        } catch {
            runtimeUnavailableReason = "Could not load the authored rack scene: \(error.localizedDescription)"
            DiagnosticsLog.shared.record("example.failed", component: "app", level: .error)
        }
    }

    func connect() {
        retryAction = .connect
        if lastError != nil { resetConnection() }
        startConnection()
    }

    func disconnect() {
        cancelPendingInput()
        resetConnection()
    }

    func appDidBecomeActive() {
        guard !isAppActive else { return }
        isAppActive = true
        DiagnosticsLog.shared.record("app.active", component: "app")
        // A new installation without configuration still supports the local scene.
        guard !backendURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        startConnection()
    }

    func appDidEnterBackground() {
        isAppActive = false
        disconnect()
        DiagnosticsLog.shared.record("app.background", component: "app")
    }

    func retryLastAction() {
        if interactionError == nil, conversation.lastError != nil || controller.lastError != nil {
            if conversation.lastError?.localizedCaseInsensitiveContains("microphone") == true {
                requestMicrophone()
            } else {
                connect()
            }
            return
        }
        switch retryAction {
        case .connect: connect()
        case .sendText: sendComposer()
        case .microphone: requestMicrophone()
        case .loadRack: loadRack()
        }
    }

    /// Every caller joins one connection attempt; text and microphone never race setup.
    @discardableResult
    private func startConnection() -> Bool {
        guard isAppActive else { return false }
        let requested: BackendConnectionConfiguration
        do {
            requested = try BackendConnectionConfiguration(address: backendURL, token: sessionAuthToken)
        } catch {
            reportConnectionFailure(error.localizedDescription)
            return false
        }
        if connectionConfiguration == requested, isConnected || connectionTask != nil { return true }

        resetConnection()
        interactionError = nil
        SessionConfigurationStore().save(requested)
        connectionConfiguration = requested
        isEstablishingConnection = true
        let attempt = connectionAttempt
        let configuration = VoiceSessionConfiguration(
            backendBaseURL: requested.url,
            sessionID: "conversation_\(attempt.uuidString.lowercased())",
            sessionAuthToken: requested.token.isEmpty ? nil : requested.token
        )
        controller.connect(url: requested.url, authToken: requested.token)
        connectionTask = Task { [weak self] in
            guard let self else { return false }
            defer {
                if self.connectionAttempt == attempt {
                    self.connectionTask = nil
                    self.isEstablishingConnection = false
                }
            }
            // Scene transport and Realtime each own finite handshake/network deadlines.
            // This local bound also protects against a missing scene state callback.
            let deadline = ContinuousClock.now.advanced(by: .seconds(16))
            while self.controller.connectionState == .connecting {
                do { try await Task.sleep(for: .milliseconds(50)) }
                catch { return false }
                guard self.connectionAttempt == attempt, self.isAppActive else { return false }
                if ContinuousClock.now >= deadline {
                    self.controller.disconnect()
                    self.reportConnectionFailure("Couldn’t connect to Astra. Check the connection and retry.")
                    return false
                }
            }
            guard !Task.isCancelled, self.connectionAttempt == attempt, self.isAppActive else { return false }
            guard self.controller.connectionState == .connected else {
                self.reportConnectionFailure("Couldn’t reach Astra. Check the connection and retry.")
                return false
            }
            let connected = await self.conversation.connect(configuration: configuration)
            guard !Task.isCancelled, self.connectionAttempt == attempt, self.isAppActive else { return false }
            let ready = connected && self.controller.connectionState == .connected
            if !ready {
                // A partial connection is not a usable conversation. Preserve the raw
                // cause in diagnostics while presenting one actionable error.
                self.conversation.disconnect()
                self.controller.disconnect()
                self.reportConnectionFailure("Couldn’t start the conversation. Please retry.")
            }
            DiagnosticsLog.shared.record("connection.finished", component: "app", correlationID: configuration.sessionID,
                                         fields: ["ready": String(ready)])
            return ready
        }
        return true
    }

    private func reportConnectionFailure(_ message: String) {
        interactionError = message
        retryAction = isSubmitting ? .sendText : (isRequestingMicrophone ? .microphone : .connect)
    }

    private func ensureConnected() async -> Bool {
        guard startConnection() else { return false }
        guard let task = connectionTask else { return isConnected && isAppActive && !Task.isCancelled }
        let attempt = connectionAttempt
        let ready = await task.value
        return ready && !Task.isCancelled && connectionAttempt == attempt && isAppActive && isConnected
    }

    private func resetConnection() {
        connectionAttempt = UUID()
        connectionTask?.cancel()
        connectionTask = nil
        connectionConfiguration = nil
        isEstablishingConnection = false
        conversation.disconnect()
        controller.disconnect()
        turnSceneIDs.removeAll()
        for lock in speechLocks.values { controller.endSpeech(lock) }
        speechLocks.removeAll()
        latestSpeechLock = nil
    }

    func sendComposer() {
        let text = composerText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !isSubmitting else { return }
        guard text.utf8.count <= 20_000 else {
            interactionError = "That message is too long. Shorten it and try again."
            return
        }
        let submission: TextSubmission
        if let failedSubmission, failedSubmission.text == text {
            submission = failedSubmission
        } else {
            submission = TextSubmission(text: text, sceneID: controller.acceptedScene.sceneId,
                                        nodeIDs: controller.selection?.nodeIDs ?? [])
        }
        failedSubmission = submission
        retryAction = .sendText
        interactionError = nil
        isSubmitting = true
        let attempt = UUID()
        submissionAttempt = attempt
        DiagnosticsLog.shared.record("text.queued", component: "app", correlationID: attempt.uuidString,
                                     fields: ["selection_count": String(submission.nodeIDs.count), "connected": String(isConnected)])
        submissionTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.submissionAttempt == attempt {
                    self.submissionTask = nil
                    self.isSubmitting = false
                }
            }
            guard await self.ensureConnected(), !Task.isCancelled, self.submissionAttempt == attempt else { return }
            let existingIDs = Set(self.controller.acceptedScene.document.nodes.map(\.nodeId))
            guard submission.sceneID == self.controller.acceptedScene.sceneId,
                  submission.nodeIDs.allSatisfy(existingIDs.contains) else {
                self.failedSubmission = nil
                self.interactionError = "The scene changed while connecting. Send again to use the current scene."
                return
            }
            let requestID = "turn_\(UUID().uuidString.lowercased())"
            self.turnSceneIDs[requestID] = submission.sceneID
            if self.conversation.sendText(submission.text, nodeIDs: submission.nodeIDs, requestID: requestID) {
                self.lastSubmittedRequestID = requestID
                // The user can keep editing while connecting; never erase a newer draft.
                if self.composerText.trimmingCharacters(in: .whitespacesAndNewlines) == submission.text {
                    self.composerText = ""
                }
                self.failedSubmission = nil
                // A later narration failure must never repeat an installed scene edit.
                self.retryAction = .connect
                self.interactionError = nil
                DiagnosticsLog.shared.record("text.submitted", component: "app", correlationID: requestID,
                                             fields: ["selection_count": String(submission.nodeIDs.count), "characters": String(submission.text.count)])
            } else {
                self.turnSceneIDs.removeValue(forKey: requestID)
                self.interactionError = "Couldn’t send your message. Please retry."
            }
        }
    }

    func requestMicrophone() {
        guard !isRequestingMicrophone else { return }
        interactionError = nil
        retryAction = .microphone
        isRequestingMicrophone = true
        let enable = !conversation.isMicrophoneEnabled
        let attempt = UUID()
        microphoneAttempt = attempt
        microphoneTask = Task { [weak self] in
            guard let self else { return }
            defer {
                if self.microphoneAttempt == attempt {
                    self.microphoneTask = nil
                    self.isRequestingMicrophone = false
                }
            }
            if enable {
                guard await self.ensureConnected(), !Task.isCancelled, self.microphoneAttempt == attempt else { return }
            }
            let changed = await self.conversation.setMicrophoneEnabled(enable)
            guard !Task.isCancelled, self.microphoneAttempt == attempt else { return }
            if !changed {
                self.interactionError = nil // The microphone error is translated by lastError.
                if self.conversation.lastError == nil {
                    self.interactionError = "Couldn’t start the microphone. Please retry."
                }
            }
        }
    }

    private func cancelPendingInput() {
        submissionAttempt = UUID()
        submissionTask?.cancel()
        submissionTask = nil
        isSubmitting = false
        failedSubmission = nil
        microphoneAttempt = UUID()
        microphoneTask?.cancel()
        microphoneTask = nil
        isRequestingMicrophone = false
    }

    func stop() {
        cancelPendingInput()
        assetLoadAttempt = UUID()
        assetLoadTask?.cancel()
        assetLoadTask = nil
        assetLoadStatus = nil
        assetLoadPhase = nil
        conversation.interrupt()
        controller.stop()
        turnSceneIDs.removeAll()
    }

    func undo() {
        cancelPendingInput()
        assetLoadAttempt = UUID()
        assetLoadTask?.cancel()
        assetLoadTask = nil
        assetLoadStatus = nil
        assetLoadPhase = nil
        conversation.interrupt()
        controller.undo()
        turnSceneIDs.removeAll()
    }

    private func executeSceneTool(_ request: RealtimeSceneToolRequest) async -> RealtimeSceneToolResult {
        guard !Task.isCancelled, turnSceneIDs[request.requestID] == controller.acceptedScene.sceneId else {
            return RealtimeSceneToolResult(status: "cancelled", requestID: request.requestID, error: "The selected scene or turn changed before execution.")
        }
        let knownIDs = Set(controller.acceptedScene.document.nodes.map(\.nodeId))
        guard request.nodeIDs.allSatisfy(knownIDs.contains) else {
            return RealtimeSceneToolResult(status: "failed", requestID: request.requestID, error: "The selected component is no longer present. Select it again.")
        }
        DiagnosticsLog.shared.record("tool.executing", component: "app", correlationID: request.requestID, fields: ["source": request.source.rawValue])
        let result = await controller.execute(
            text: request.text,
            selection: request.nodeIDs.isEmpty ? nil : SceneSelection(nodeIDs: request.nodeIDs),
            requestID: request.requestID
        )
        turnSceneIDs.removeValue(forKey: request.requestID)
        DiagnosticsLog.shared.record("tool.finished", component: "app", correlationID: request.requestID, fields: ["status": result.status.rawValue, "revision": String(result.revision)])
        return RealtimeSceneToolResult(
            status: result.status.rawValue,
            requestID: result.requestID,
            sceneID: result.sceneID,
            revision: Int(result.revision),
            intentEpoch: Int(result.intentEpoch),
            proposalRequestIDs: result.proposalRequestIDs,
            explanation: result.explanation,
            error: result.error
        )
    }

}
