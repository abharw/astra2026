import Foundation
import Observation
import SpatialApple
import os
import Synchronization

nonisolated private final class WebSocketSendGate: Sendable {
    private let continuation: Mutex<CheckedContinuation<Void, Error>?>

    init(_ continuation: CheckedContinuation<Void, Error>) {
        self.continuation = Mutex(continuation)
    }

    @discardableResult
    func resolve(_ result: Result<Void, Error>) -> Bool {
        let pending = continuation.withLock { continuation in
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return false }
        pending.resume(with: result)
        return true
    }
}

@MainActor
@Observable
final class RealtimeSession {
    private(set) var isConnected = false
    private(set) var isConnecting = false
    private(set) var isMicrophoneEnabled = false
    private(set) var activity: RealtimeActivity = .idle {
        didSet {
            guard activity != oldValue else { return }
            diagnostic("state_changed", fields: [
                "from": oldValue.diagnosticName, "to": activity.diagnosticName,
            ])
        }
    }
    private(set) var lastError: String?
    private(set) var lastAssistantText = ""
    private(set) var liveTranscript = ""
    private(set) var audioRouteSummary: String?

    var statusText: String { activity.statusText }

    @ObservationIgnored private let logger = Logger(subsystem: "com.astra.spatialdemo", category: "realtime-session")
    @ObservationIgnored private let selectionProvider: @MainActor () -> [String]?
    @ObservationIgnored private let selectionSnapshotProvider: @MainActor () -> [String]?
    @ObservationIgnored private let onSpeechStarted: @MainActor (VoiceSpeechBinding) -> Void
    @ObservationIgnored private let onSpeechDiscarded: @MainActor (VoiceSpeechBinding) -> Void
    @ObservationIgnored private let executeScene: @MainActor (RealtimeSceneToolRequest) async -> RealtimeSceneToolResult
    @ObservationIgnored private let dependencies: RealtimeDependencies

    @ObservationIgnored private var webSocket: (any RealtimeSocket)?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var outboundTask: Task<Void, Never>?
    @ObservationIgnored private var handshakeTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var sceneExecutionTask: Task<Void, Never>?
    @ObservationIgnored private var responseDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var microphoneTask: Task<Void, Never>?
    @ObservationIgnored private var inputClearDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var audioSessionID: UUID?
    @ObservationIgnored private var isAudioReady = false
    @ObservationIgnored private var inputClearPending = false
    @ObservationIgnored private var inputAudioFrameCount: Int64 = 0
    @ObservationIgnored private var inputCaptureFloorMS: Int64 = 0
    @ObservationIgnored private var connectWaiters: [CheckedContinuation<Bool, Never>] = []
    @ObservationIgnored private var outboundMessages: [OutboundMessage] = []
    @ObservationIgnored private var outboundHead = 0
    @ObservationIgnored private var outboundByteCount = 0
    @ObservationIgnored private var didSendSessionConfiguration = false
    @ObservationIgnored private var onsetDetector = VoiceOnsetDetector()
    @ObservationIgnored private var pendingLocalBindings: [SpeechHint] = []
    @ObservationIgnored private var selectionHistory: [SelectionSample] = []
    @ObservationIgnored private var discardedHintThroughFrame: Int64?
    @ObservationIgnored private var lastAdmittedSpeechStartMS: Int64?
    @ObservationIgnored private var transcriptItem: (itemID: String, requestID: String, captureID: UUID)?
    @ObservationIgnored private var speechBindingsByItemID: [String: VoiceSpeechBinding] = [:]
    @ObservationIgnored private var speechCaptureIDs: [String: UUID] = [:]
    @ObservationIgnored private var consumedSpeechItemIDs = Set<String>()
    @ObservationIgnored private var consumedSpeechItemOrder: [String] = []
    @ObservationIgnored private var generation = 0
    @ObservationIgnored private var connectionAttemptID = UUID()
    @ObservationIgnored private var microphoneEnableID = UUID()
    @ObservationIgnored private var outboundDrainID = UUID()
    @ObservationIgnored private var activeTurn: ActiveTurn?
    @ObservationIgnored private var executedCallIDs = Set<String>()
    @ObservationIgnored private var pendingCalls: [String: PendingCall] = [:]
    @ObservationIgnored private var sessionCorrelationID = UUID().uuidString
    @ObservationIgnored private var receivedFirstOutputAudio = false
    @ObservationIgnored private var socketEventCounts: [String: Int] = [:]
    @ObservationIgnored private var socketEventBytes = 0
    @ObservationIgnored private var lastSocketSummaryAt = Date()
    @ObservationIgnored private var outboundEventCounts: [String: Int] = [:]
    @ObservationIgnored private var lastOutboundSummaryAt = Date()
    @ObservationIgnored private var microphoneBufferCount = 0
    @ObservationIgnored private var microphoneFrameCount = 0
    @ObservationIgnored private var lastMicrophoneSummaryAt = Date()

    private enum ResponsePhase: String {
        case requestingTool = "tool"
        case executingTool = "executing_tool"
        case final
    }

    private struct OutboundMessage {
        enum Kind {
            case control
            case audio(captureID: UUID, frameCount: Int)
            case clearAudio
        }
        let text: String
        let kind: Kind
        var byteCount: Int { text.utf8.count }
    }

    private struct PendingCall {
        let connectionID: UUID
        let turn: ActiveTurn
    }

    private struct SpeechHint {
        let binding: VoiceSpeechBinding
        let captureID: UUID
        let onsetFrame: Int64
    }

    private struct SelectionSample {
        let captureID: UUID
        var startFrame: Int64
        var endFrame: Int64
        let nodeIDs: [String]?
    }

    private struct ActiveTurn {
        let generation: Int
        let requestID: String
        let nodeIDs: [String]
        let source: RealtimeInputSource
        var binding: VoiceSpeechBinding?
        var phase: ResponsePhase
        var responseID: String?
        var callID: String?
        var providerResponsePending: Bool
        var outputItemID: String?
        var playbackFinished: Bool
    }

    @ObservationIgnored private lazy var audioIO = dependencies.makeAudioIO {
        [weak self] event in self?.handleAudioEvent(event)
    }

    init(
        selectionProvider: @escaping @MainActor () -> [String]?,
        onSpeechStarted: @escaping @MainActor (VoiceSpeechBinding) -> Void,
        onSpeechDiscarded: @escaping @MainActor (VoiceSpeechBinding) -> Void = { _ in },
        executeScene: @escaping @MainActor (RealtimeSceneToolRequest) async -> RealtimeSceneToolResult,
        selectionSnapshotProvider: (@MainActor () -> [String]?)? = nil,
        dependencies: RealtimeDependencies = .live
    ) {
        self.selectionProvider = selectionProvider
        self.selectionSnapshotProvider = selectionSnapshotProvider ?? selectionProvider
        self.onSpeechStarted = onSpeechStarted
        self.onSpeechDiscarded = onSpeechDiscarded
        self.executeScene = executeScene
        self.dependencies = dependencies
    }

    func connect(configuration: VoiceSessionConfiguration) async -> Bool {
        if isConnected { return true }
        if isConnecting {
            return await withCheckedContinuation { connectWaiters.append($0) }
        }
        resetTransport()
        let attemptID = UUID()
        connectionAttemptID = attemptID
        sessionCorrelationID = UUID().uuidString
        isConnecting = true
        activity = .fetchingCredential
        lastError = nil
        diagnostic("connect_requested")
        let startedAt = Date()
        do {
            let credential = try await fetchClientSecret(configuration: configuration)
            guard isConnecting, connectionAttemptID == attemptID else {
                diagnostic("credential_callback_ignored", level: .warning, fields: ["reason": "stale_attempt"])
                return false
            }
            diagnostic("credential_fetch_completed", fields: [
                "latency_ms": milliseconds(since: startedAt), "status": "success",
            ])
            guard credential.clientSecret.expiresAt > Date().timeIntervalSince1970 + 5 else {
                throw VoiceSessionError.credentialExpired
            }
            try openRealtime(model: credential.model, clientSecret: credential.clientSecret.value)
            return await withCheckedContinuation { connectWaiters.append($0) }
        } catch {
            guard connectionAttemptID == attemptID else { return false }
            failConnection(error)
            return false
        }
    }

    @discardableResult
    func sendText(_ text: String, nodeIDs: [String], requestID: String) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isConnected, !text.isEmpty, text.utf8.count <= 20_000 else { return false }
        resetInputCapture()
        retireActiveTurn()
        lastError = nil
        let turn = beginTurn(requestID: requestID, nodeIDs: nodeIDs, source: .typed, binding: nil)
        do {
            try enqueue(RealtimeWire.textInput(text, eventID: "turn_\(turn.generation)_input"))
            try enqueue(RealtimeWire.toolResponse(
                generation: turn.generation, requestID: requestID, source: .typed
            ))
            scheduleResponseDeadline(for: turn)
            diagnostic("typed_turn_sent", correlationID: requestID, fields: [
                "generation": String(turn.generation), "input_length": String(text.count),
                "target_count": String(nodeIDs.count),
            ])
            return true
        } catch {
            failTurn(error, generation: turn.generation)
            return false
        }
    }

    @discardableResult
    func setMicrophoneEnabled(_ enabled: Bool) async -> Bool {
        if !enabled {
            microphoneEnableID = UUID()
            guard isMicrophoneEnabled else { return true }
            if activeTurn?.source == .voice { retireActiveTurn() }
            invalidateAudioCapture()
            audioIO.stop()
            isMicrophoneEnabled = false
            resetInputCapture()
            activity = currentTurnActivity
            diagnostic("microphone_disabled")
            return true
        }
        guard isConnected else { return false }
        guard !isMicrophoneEnabled else { return true }
        let enableID = UUID()
        microphoneEnableID = enableID
        let connectionID = connectionAttemptID
        activity = .requestingPermission
        diagnostic("microphone_permission_requested")
        let granted = await dependencies.requestMicrophonePermission()
        guard !Task.isCancelled, isConnected, microphoneEnableID == enableID, connectionAttemptID == connectionID else {
            diagnostic("microphone_permission_callback_ignored", level: .warning)
            return false
        }
        diagnostic("microphone_permission_resolved", fields: ["granted": String(granted)])
        guard granted else {
            lastError = VoiceSessionError.microphoneDenied.errorDescription
            activity = currentTurnActivity
            return false
        }
        do {
            let capture = try audioIO.start()
            isMicrophoneEnabled = true
            isAudioReady = true
            audioSessionID = capture.sessionID
            audioRouteSummary = capture.route.summary
            lastError = nil
            resetInputCapture()
            guard isConnected, isMicrophoneEnabled else { return false }
            consumeMicrophone(capture)
            activity = currentTurnActivity
            return true
        } catch {
            handleMicrophoneFailure(error)
            return false
        }
    }

    private func consumeMicrophone(_ capture: AudioCapture) {
        microphoneTask?.cancel()
        microphoneTask = Task { [weak self] in
            do {
                for try await chunk in capture.stream {
                    guard !Task.isCancelled, let self,
                          self.audioSessionID == capture.sessionID else { return }
                    self.enqueueMicrophonePCM(chunk)
                }
                guard !Task.isCancelled, let self, self.audioSessionID == capture.sessionID else { return }
                self.handleMicrophoneFailure(VoiceSessionError.microphoneUnavailable)
            } catch {
                guard !Task.isCancelled, let self, self.audioSessionID == capture.sessionID else { return }
                self.handleMicrophoneFailure(error)
            }
        }
    }

    private func invalidateAudioCapture() {
        audioSessionID = nil
        isAudioReady = false
        microphoneTask?.cancel()
        microphoneTask = nil
        inputClearDeadlineTask?.cancel()
        inputClearDeadlineTask = nil
    }

    func interrupt() {
        resetInputCapture()
        retireActiveTurn()
    }

    private func retireActiveTurn() {
        generation &+= 1
        let interrupted = activeTurn
        sceneExecutionTask?.cancel()
        sceneExecutionTask = nil
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        if let binding = interrupted?.binding { releaseBinding(binding) }
        activeTurn = nil
        receivedFirstOutputAudio = false
        lastAssistantText = ""
        do {
            if let interrupted, interrupted.providerResponsePending {
                try enqueue(RealtimeWire.cancelResponse(responseID: interrupted.responseID))
            }
            if let cut = audioIO.interruptPlayback() { try enqueueTruncation(cut) }
        } catch { diagnostic("interrupt_send_failed", level: .warning) }
        if let interrupted {
            diagnostic("turn_cancelled", correlationID: interrupted.requestID, fields: [
                "generation": String(interrupted.generation), "phase": interrupted.phase.rawValue,
            ])
        }
        activity = isMicrophoneEnabled ? .listening : (isConnected ? .ready : .idle)
    }

    func disconnect() {
        diagnostic("disconnect_requested")
        connectionAttemptID = UUID()
        microphoneEnableID = UUID()
        retireActiveTurn()
        isConnecting = false
        isConnected = false
        resolveConnectWaiters(false)
        resetTransport()
        activity = .idle
        lastAssistantText = ""
        lastError = nil
    }

    private func fetchClientSecret(configuration: VoiceSessionConfiguration) async throws -> RealtimeClientSecretResponse {
        guard let scheme = configuration.backendBaseURL.scheme, scheme == "http" || scheme == "https" else {
            throw VoiceSessionError.invalidBackendURL
        }
        let endpoint = configuration.backendBaseURL.appending(path: "realtime").appending(path: "client-secret")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.sessionAuthToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: ["sessionId": configuration.sessionID])
        diagnostic("credential_fetch_started")
        let (data, response) = try await dependencies.fetchCredentialData(request)
        guard let http = response as? HTTPURLResponse else { throw VoiceSessionError.malformedCredentialResponse }
        diagnostic("credential_fetch_http_status", level: http.statusCode < 300 ? .info : .warning, fields: [
            "status_code": String(http.statusCode), "response_bytes": String(data.count),
        ])
        guard (200..<300).contains(http.statusCode) else { throw VoiceSessionError.backend(http.statusCode) }
        guard let decoded = try? JSONDecoder().decode(RealtimeClientSecretResponse.self, from: data),
              !decoded.clientSecret.value.isEmpty, !decoded.model.isEmpty
        else { throw VoiceSessionError.malformedCredentialResponse }
        return decoded
    }

    private func openRealtime(model: String, clientSecret: String) throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw VoiceSessionError.disconnected }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let socket = dependencies.makeSocket(request)
        socket.maximumMessageSize = 16 * 1_024 * 1_024
        webSocket = socket
        activity = .connecting
        diagnostic("realtime_socket_connecting")
        socket.resume()
        beginReceiving(from: socket)
        handshakeTimeoutTask = Task { [weak self, weak socket] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isConnecting, self.webSocket === socket else { return }
            self.failConnection(VoiceSessionError.realtime("The Realtime handshake timed out."))
        }
    }

    private func beginReceiving(from socket: any RealtimeSocket) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, weak socket] in
            guard let socket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await socket.receive()
                    guard !Task.isCancelled, let self, self.webSocket === socket else { return }
                    guard let text = RealtimeWire.text(from: message) else {
                        self.diagnostic("realtime_message_ignored", level: .warning)
                        continue
                    }
                    try self.handleRealtimeEvent(text)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.webSocket === socket else { return }
                self.failConnection(error)
            }
        }
    }

    private func handleRealtimeEvent(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else {
            diagnostic("realtime_event_ignored", level: .warning, fields: ["reason": "invalid_envelope"])
            return
        }
        recordSocketEvent(type: type, bytes: data.count)
        switch type {
        case "session.created":
            guard !didSendSessionConfiguration else { return }
            didSendSessionConfiguration = true
            try enqueue(RealtimeWire.sessionUpdate())
            diagnostic("realtime_session_configuration_sent")
        case "session.updated":
            guard isConnecting else {
                diagnostic("session_updated_ignored", level: .warning, fields: ["reason": "not_connecting"])
                return
            }
            handshakeTimeoutTask?.cancel()
            handshakeTimeoutTask = nil
            isConnecting = false
            isConnected = true
            activity = .ready
            diagnostic("realtime_session_configuration_acknowledged")
            resolveConnectWaiters(true)
        case "input_audio_buffer.speech_started":
            bindRemoteSpeechItem(event)
        case "input_audio_buffer.speech_stopped":
            finishRemoteSpeech(event)
        case "input_audio_buffer.cleared":
            guard inputClearPending else { return }
            inputClearPending = false
            inputClearDeadlineTask?.cancel()
            inputClearDeadlineTask = nil
            diagnostic("input_audio_clear_acknowledged", fields: ["capture_floor_ms": String(inputCaptureFloorMS)])
        case "input_audio_buffer.committed":
            startCommittedVoiceTurn(event)
        case "conversation.item.input_audio_transcription.delta":
            if ownsSpeechTranscript(event), let delta = event["delta"] as? String {
                liveTranscript += delta
            }
        case "conversation.item.input_audio_transcription.completed":
            handleTranscriptionCompleted(event)
        case "conversation.item.input_audio_transcription.failed":
            handleTranscriptionFailed(event)
        case "response.created":
            handleResponseCreated(event)
        case "response.done":
            handleResponseDone(event)
        case "response.output_text.delta", "response.output_audio_transcript.delta":
            handleAssistantTextDelta(event)
        case "response.output_audio.delta":
            try handleAudioDelta(event)
        case "response.output_audio.done":
            if let itemID = event["item_id"] as? String, let responseID = event["response_id"] as? String,
               let turn = activeTurn, turn.phase == .final, turn.source == .voice,
               turn.responseID == responseID, turn.outputItemID == itemID
            {
                audioIO.markOutputComplete(itemID: itemID)
            } else {
                diagnostic("output_audio_done_ignored", level: .warning, fields: ["reason": "stale_or_unowned"])
            }
        case "error":
            let errorObject = event["error"] as? [String: Any]
            let code = errorObject?["code"] as? String ?? "unknown"
            diagnostic("realtime_error", level: .error, fields: ["code": code])
            if code == "response_cancel_not_active" || code == "response_cancel_not_found" { return }
            let eventID = errorObject?["event_id"] as? String ?? event["event_id"] as? String
            if let failedGeneration = generation(fromEventID: eventID), activeTurn?.generation == failedGeneration {
                failTurn(VoiceSessionError.realtime("The response request was rejected."), generation: failedGeneration)
                return
            }
            if eventID?.hasPrefix("turn_") == true { return }
            throw VoiceSessionError.realtime("The conversation service rejected an event.")
        default:
            break
        }
    }

    private func beginTurn(
        requestID: String,
        nodeIDs: [String],
        source: RealtimeInputSource,
        binding: VoiceSpeechBinding?
    ) -> ActiveTurn {
        generation &+= 1
        let turn = ActiveTurn(
            generation: generation, requestID: requestID, nodeIDs: nodeIDs,
            source: source, binding: binding, phase: .requestingTool,
            responseID: nil, callID: nil, providerResponsePending: true,
            outputItemID: nil, playbackFinished: false
        )
        activeTurn = turn
        lastError = nil
        lastAssistantText = ""
        receivedFirstOutputAudio = false
        activity = .waitingForAstra
        return turn
    }

    private func startCommittedVoiceTurn(_ event: [String: Any]) {
        guard let itemID = event["item_id"] as? String,
              !consumedSpeechItemIDs.contains(itemID),
              let binding = ownedSpeechBinding(for: event)
        else {
            diagnostic("voice_commit_ignored", level: .warning, fields: ["reason": "missing_binding"])
            return
        }
        rememberConsumedSpeechItem(itemID)
        retireActiveTurn()
        let turn = beginTurn(
            requestID: binding.requestID, nodeIDs: binding.nodeIDs,
            source: .voice, binding: binding
        )
        do {
            try enqueue(RealtimeWire.toolResponse(
                generation: turn.generation, requestID: turn.requestID, source: .voice
            ))
            scheduleResponseDeadline(for: turn)
            diagnostic("voice_turn_committed", correlationID: turn.requestID, fields: [
                "generation": String(turn.generation), "item_id": itemID,
                "target_count": String(turn.nodeIDs.count),
            ])
        } catch { failTurn(error, generation: turn.generation) }
    }

    private func handleResponseCreated(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let responseID = response["id"] as? String,
              let fence = responseFence(response), var turn = activeTurn,
              fence.generation == turn.generation, fence.requestID == turn.requestID,
              fence.phase == turn.phase
        else {
            diagnostic("response_created_ignored", level: .warning, fields: ["reason": "stale_or_unfenced"])
            return
        }
        turn.responseID = responseID
        turn.providerResponsePending = true
        activeTurn = turn
        diagnostic("response_created", correlationID: turn.requestID, fields: [
            "generation": String(turn.generation), "phase": turn.phase.rawValue,
            "response_id": responseID,
        ])
    }

    private func handleResponseDone(_ event: [String: Any]) {
        guard let response = event["response"] as? [String: Any],
              let fence = responseFence(response), let turn = activeTurn,
              fence.generation == turn.generation, fence.requestID == turn.requestID,
              fence.phase == turn.phase
        else {
            diagnostic("response_done_ignored", level: .warning, fields: ["reason": "stale_or_unfenced"])
            return
        }
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        var completedTurn = turn
        completedTurn.providerResponsePending = false
        activeTurn = completedTurn
        guard response["status"] as? String == "completed" else {
            diagnostic("response_done_not_completed", level: .warning, correlationID: turn.requestID, fields: [
                "generation": String(turn.generation), "phase": turn.phase.rawValue,
                "status": response["status"] as? String ?? "unknown",
            ])
            failTurn(VoiceSessionError.realtime("The response did not complete."), generation: turn.generation)
            return
        }
        switch turn.phase {
        case .requestingTool:
            guard let call = extractSingleToolCall(response), call.name == "ask_astra",
                  !executedCallIDs.contains(call.callID),
                  let requestText = validatedRequest(arguments: call.arguments)
            else {
                failTurn(VoiceSessionError.invalidToolCall, generation: turn.generation)
                return
            }
            executedCallIDs.insert(call.callID)
            var executing = turn
            executing.phase = .executingTool
            executing.callID = call.callID
            executing.responseID = nil
            executing.providerResponsePending = false
            activeTurn = executing
            pendingCalls[call.callID] = PendingCall(connectionID: connectionAttemptID, turn: executing)
            activity = .waitingForAstra
            executeTool(requestText: requestText, turn: executing)
        case .executingTool:
            diagnostic("response_done_ignored", level: .warning, correlationID: turn.requestID, fields: [
                "reason": "no_response_expected_while_executing_tool",
            ])
        case .final:
            diagnostic("final_response_completed", correlationID: turn.requestID, fields: [
                "generation": String(turn.generation), "source": turn.source.rawValue,
                "assistant_length": String(lastAssistantText.count),
            ])
            if completedTurn.source == .typed {
                activeTurn = nil
                activity = isMicrophoneEnabled ? .listening : .ready
            } else if !receivedFirstOutputAudio {
                activeTurn = nil
                activity = isMicrophoneEnabled ? .listening : .ready
            } else if completedTurn.playbackFinished {
                activeTurn = nil
                activity = isMicrophoneEnabled ? .listening : .ready
            } else {
                activity = .delivering
            }
        }
    }

    private func executeTool(requestText: String, turn: ActiveTurn) {
        diagnostic("ask_astra_started", correlationID: turn.requestID, fields: [
            "generation": String(turn.generation), "request_length": String(requestText.count),
            "target_count": String(turn.nodeIDs.count), "source": turn.source.rawValue,
        ])
        let request = RealtimeSceneToolRequest(
            requestID: turn.requestID, text: requestText,
            nodeIDs: turn.nodeIDs, source: turn.source
        )
        sceneExecutionTask = Task { [weak self] in
            guard let self else { return }
            let result = await self.executeScene(request)
            self.finishTool(result: result, turn: turn)
        }
    }

    private func finishTool(result: RealtimeSceneToolResult, turn: ActiveTurn) {
        guard let callID = turn.callID, let pending = pendingCalls[callID],
              pending.connectionID == connectionAttemptID,
              pending.turn.generation == turn.generation,
              pending.turn.requestID == turn.requestID, isConnected else { return }
        let terminalResult = result.requestID == turn.requestID ? result : RealtimeSceneToolResult(
            status: "failed", requestID: turn.requestID,
            error: "The scene result did not match this request. Its outcome is unconfirmed.")
        diagnostic("ask_astra_completed", correlationID: turn.requestID, fields: [
            "generation": String(turn.generation), "status": result.status,
            "scene_id": result.sceneID ?? "", "revision": result.revision.map(String.init) ?? "",
            "intent_epoch": result.intentEpoch.map(String.init) ?? "",
            "explanation_length": String(result.explanation?.count ?? 0),
        ])
        if let binding = turn.binding { releaseBinding(binding) }
        do {
            try enqueue(RealtimeWire.functionOutput(callID: callID, result: terminalResult))
            pendingCalls.removeValue(forKey: callID)
            guard let current = activeTurn, current.generation == turn.generation,
                  current.phase == .executingTool, current.callID == callID else {
                diagnostic("superseded_tool_output_returned", correlationID: turn.requestID)
                return
            }
            var final = turn
            final.phase = .final
            final.responseID = nil
            final.providerResponsePending = true
            final.outputItemID = nil
            final.playbackFinished = false
            final.binding = nil
            activeTurn = final
            try enqueue(RealtimeWire.finalResponse(
                generation: final.generation,
                requestID: final.requestID,
                source: final.source,
                result: terminalResult
            ))
            scheduleResponseDeadline(for: final)
            sceneExecutionTask = nil
            activity = .delivering
        } catch { failConnection(error) }
    }

    private struct ToolCall { let name: String; let callID: String; let arguments: String }

    private func extractSingleToolCall(_ response: [String: Any]) -> ToolCall? {
        guard let output = response["output"] as? [[String: Any]] else { return nil }
        let calls = output.compactMap { item -> ToolCall? in
            guard item["type"] as? String == "function_call",
                  let name = item["name"] as? String,
                  let callID = item["call_id"] as? String,
                  let arguments = item["arguments"] as? String
            else { return nil }
            return ToolCall(name: name, callID: callID, arguments: arguments)
        }
        return calls.count == 1 ? calls[0] : nil
    }

    private func validatedRequest(arguments: String) -> String? {
        guard arguments.utf8.count <= 24_000,
              let data = arguments.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object.count == 1, let raw = object["request"] as? String
        else { return nil }
        let request = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return !request.isEmpty && request.utf8.count <= 20_000 ? request : nil
    }

    private func responseFence(_ response: [String: Any]) -> (generation: Int, requestID: String, phase: ResponsePhase)? {
        guard let metadata = response["metadata"] as? [String: Any],
              let generationText = metadata["generation"] as? String,
              let generation = Int(generationText),
              let requestID = metadata["request_id"] as? String,
              let phaseText = metadata["phase"] as? String,
              let phase = ResponsePhase(rawValue: phaseText)
        else { return nil }
        return (generation, requestID, phase)
    }

    private func handleAssistantTextDelta(_ event: [String: Any]) {
        guard let turn = activeTurn, turn.phase == .final,
              event["response_id"] as? String == turn.responseID,
              let delta = event["delta"] as? String
        else { return }
        lastAssistantText += delta
    }

    private func handleAudioDelta(_ event: [String: Any]) throws {
        guard isMicrophoneEnabled, isAudioReady,
              var turn = activeTurn, turn.phase == .final, turn.source == .voice,
              event["response_id"] as? String == turn.responseID,
              let encoded = event["delta"] as? String,
              let data = Data(base64Encoded: encoded),
              let itemID = event["item_id"] as? String
        else {
            diagnostic("output_audio_ignored", level: .debug, fields: ["reason": "stale_or_non_final"])
            return
        }
        guard turn.outputItemID == nil || turn.outputItemID == itemID else {
            diagnostic("output_audio_ignored", level: .warning, fields: ["reason": "unexpected_item"])
            return
        }
        turn.outputItemID = itemID
        activeTurn = turn
        if !receivedFirstOutputAudio {
            receivedFirstOutputAudio = true
            diagnostic("final_first_audio", correlationID: turn.requestID, fields: [
                "response_id": turn.responseID ?? "unknown", "audio_bytes": String(data.count),
            ])
        }
        try audioIO.enqueuePlayback(
            data, itemID: itemID, contentIndex: event["content_index"] as? Int ?? 0
        )
        activity = .delivering
    }

    private var acceptsMicrophoneInput: Bool {
        isConnected && isMicrophoneEnabled && isAudioReady && !inputClearPending
            && audioSessionID != nil && audioIO.currentCaptureID != nil
    }

    private func enqueueMicrophonePCM(_ chunk: MicrophoneChunk) {
        guard acceptsMicrophoneInput, chunk.captureID == audioIO.currentCaptureID else { return }
        microphoneBufferCount += 1
        microphoneFrameCount += chunk.data.count / PCMCodec.bytesPerFrame
        if Date().timeIntervalSince(lastMicrophoneSummaryAt) >= 1 {
            diagnostic("microphone_pcm_summary", fields: [
                "buffer_count": String(microphoneBufferCount),
                "frame_count": String(microphoneFrameCount),
                "byte_count": String(microphoneFrameCount * PCMCodec.bytesPerFrame),
            ])
            microphoneBufferCount = 0
            microphoneFrameCount = 0
            lastMicrophoneSummaryAt = Date()
        }
        let queuedAudioFrames = outboundMessages.dropFirst(outboundHead).reduce(Int64(0)) { total, message in
            if case .audio(_, let frames) = message.kind { return total + Int64(frames) }
            return total
        }
        let frameBase = inputAudioFrameCount + queuedAudioFrames
        recordSelection(
            captureID: chunk.captureID, startFrame: frameBase,
            frameCount: chunk.data.count / PCMCodec.bytesPerFrame)
        for detection in onsetDetector.processTimed(pcm16: chunk.data) where detection.transition == .began {
            if let nodeIDs = selectionProvider() {
                // Energy detects selection timing, not an interruption. Wait for
                // owned provider VAD before cancelling work or audible output.
                let binding = VoiceSpeechBinding(
                    requestID: UUID().uuidString, nodeIDs: nodeIDs, beganAt: Date()
                )
                pendingLocalBindings.append(SpeechHint(
                    binding: binding, captureID: chunk.captureID,
                    onsetFrame: frameBase + Int64(detection.frameOffset)))
                speechCaptureIDs[binding.requestID] = chunk.captureID
                while pendingLocalBindings.count > 16 {
                    discardLostHint(pendingLocalBindings.removeFirst())
                }
                onSpeechStarted(binding)
                diagnostic("local_speech_onset", correlationID: binding.requestID, fields: [
                    "target_count": String(nodeIDs.count), "target_ids": nodeIDs.joined(separator: ","),
                ])
            } else {
                diagnostic("local_speech_onset_ambiguous", level: .warning)
            }
        }
        do {
            try enqueue(
                RealtimeWire.appendAudio(chunk.data),
                kind: .audio(captureID: chunk.captureID, frameCount: chunk.data.count / PCMCodec.bytesPerFrame))
        }
        catch { handleMicrophoneFailure(error) }
    }

    private func bindRemoteSpeechItem(_ event: [String: Any]) {
        guard acceptsMicrophoneInput, let captureID = audioIO.currentCaptureID,
              let itemID = event["item_id"] as? String,
              !consumedSpeechItemIDs.contains(itemID), speechBindingsByItemID[itemID] == nil,
              let audioStartMS = event["audio_start_ms"] as? Int64,
              audioStartMS >= inputCaptureFloorMS,
              audioStartMS <= inputAudioFrameCount * 1_000 / Int64(PCMCodec.sampleRate),
              lastAdmittedSpeechStartMS.map({ audioStartMS > $0 }) ?? true else {
            diagnostic("remote_speech_ignored", level: .warning, fields: [
                "reason": "unowned_or_before_capture", "capture_floor_ms": String(inputCaptureFloorMS),
                "audio_start_ms": (event["audio_start_ms"] as? NSNumber)?.stringValue ?? "missing",
            ])
            return
        }
        let now = Date()
        let expired = pendingLocalBindings.filter { now.timeIntervalSince($0.binding.beganAt) > 5 }
        pendingLocalBindings.removeAll { now.timeIntervalSince($0.binding.beganAt) > 5 }
        for hint in expired { discardLostHint(hint) }
        discardPendingHints { $0.onsetFrame * 1_000 < audioStartMS * Int64(PCMCodec.sampleRate) }
        let canUseHint = discardedHintThroughFrame.map {
            audioStartMS * Int64(PCMCodec.sampleRate) > $0 * 1_000
        } ?? true
        let latestHintFrame = (audioStartMS + RealtimeWire.inputPrefixPaddingMS)
            * Int64(PCMCodec.sampleRate) / 1_000 + Int64(onsetDetector.onsetWindowToleranceFrames)
        let hint: SpeechHint
        let bindingSource: String
        if canUseHint, let index = pendingLocalBindings.firstIndex(where: {
            $0.captureID == captureID && $0.onsetFrame <= latestHintFrame
        }) {
            hint = pendingLocalBindings.remove(at: index)
            bindingSource = "local_onset"
        } else if let historical = historicalSpeechHint(audioStartMS: audioStartMS, captureID: captureID) {
            hint = historical
            bindingSource = "selection_history"
        } else {
            diagnostic("remote_speech_binding_missing", level: .warning, fields: [
                "item_id": itemID, "audio_start_ms": String(audioStartMS),
            ])
            return
        }
        let binding = hint.binding
        guard speechCaptureIDs[binding.requestID] == captureID else {
            releaseBinding(binding)
            return
        }
        retireActiveTurn()
        if let replaced = speechBindingsByItemID.updateValue(binding, forKey: itemID) {
            releaseBinding(replaced)
        }
        lastAdmittedSpeechStartMS = audioStartMS
        transcriptItem = (itemID, binding.requestID, captureID)
        liveTranscript = ""
        diagnostic("remote_speech_bound", correlationID: binding.requestID, fields: [
            "item_id": itemID, "target_count": String(binding.nodeIDs.count),
            "audio_start_ms": String(audioStartMS), "capture_floor_ms": String(inputCaptureFloorMS),
            "local_onset_ms": String(hint.onsetFrame * 1_000 / Int64(PCMCodec.sampleRate)),
            "binding_source": bindingSource,
        ])
    }

    private func recordSelection(captureID: UUID, startFrame: Int64, frameCount: Int) {
        guard frameCount > 0 else { return }
        let endFrame = startFrame + Int64(frameCount)
        let nodeIDs = selectionSnapshotProvider()
        if let last = selectionHistory.last, last.captureID == captureID,
           last.endFrame == startFrame, last.nodeIDs == nodeIDs {
            selectionHistory[selectionHistory.count - 1].endFrame = endFrame
        } else {
            selectionHistory.append(SelectionSample(
                captureID: captureID, startFrame: startFrame, endFrame: endFrame, nodeIDs: nodeIDs))
        }
        let floor = max(0, endFrame - Int64(PCMCodec.sampleRate) * 10)
        selectionHistory.removeAll { $0.endFrame <= floor }
        if selectionHistory.count > 512 { selectionHistory.removeFirst(selectionHistory.count - 512) }
        if !selectionHistory.isEmpty { selectionHistory[0].startFrame = max(selectionHistory[0].startFrame, floor) }
    }

    private func historicalSpeechHint(audioStartMS: Int64, captureID: UUID) -> SpeechHint? {
        // Server VAD includes the configured prefix padding in audio_start_ms.
        // A local energy edge is optional: steady noise can span real speech.
        let onsetFrame = (audioStartMS + RealtimeWire.inputPrefixPaddingMS) * Int64(PCMCodec.sampleRate) / 1_000
        guard onsetFrame < inputAudioFrameCount,
              let sample = selectionHistory.last(where: {
                  $0.captureID == captureID && $0.startFrame <= onsetFrame && onsetFrame < $0.endFrame
              }), let nodeIDs = sample.nodeIDs else { return nil }
        let binding = VoiceSpeechBinding(requestID: UUID().uuidString, nodeIDs: nodeIDs, beganAt: Date())
        speechCaptureIDs[binding.requestID] = captureID
        onSpeechStarted(binding)
        return SpeechHint(binding: binding, captureID: captureID, onsetFrame: onsetFrame)
    }

    private func finishRemoteSpeech(_ event: [String: Any]) {
        guard ownedSpeechBinding(for: event) != nil,
              let audioEndMS = event["audio_end_ms"] as? Int64, audioEndMS >= inputCaptureFloorMS,
              audioEndMS <= inputAudioFrameCount * 1_000 / Int64(PCMCodec.sampleRate) else { return }
        // Provider silence can contain several local energy onsets. They belong
        // to this utterance; hints after its end remain available to the next one.
        discardPendingHints { $0.onsetFrame * 1_000 <= audioEndMS * Int64(PCMCodec.sampleRate) }
    }

    private func handleTranscriptionCompleted(_ event: [String: Any]) {
        guard let itemID = event["item_id"] as? String,
              ownsSpeechTranscript(event),
              let transcript = event["transcript"] as? String
        else { return }
        liveTranscript = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        diagnostic("transcription_completed", correlationID: transcriptItem?.requestID, fields: [
            "item_id": itemID, "text_bytes": String(transcript.utf8.count),
            "text_length": String(transcript.count),
        ])
    }

    private func handleTranscriptionFailed(_ event: [String: Any]) {
        let itemID = event["item_id"] as? String
        let binding = itemID.flatMap { speechBindingsByItemID[$0] }
        diagnostic("transcription_failed", level: .warning, correlationID: binding?.requestID, fields: [
            "item_id": itemID ?? "unknown",
        ])
    }

    private func releaseBinding(_ binding: VoiceSpeechBinding) {
        pendingLocalBindings.removeAll { $0.binding.requestID == binding.requestID }
        for (itemID, existing) in speechBindingsByItemID where existing.requestID == binding.requestID {
            rememberConsumedSpeechItem(itemID)
        }
        speechBindingsByItemID = speechBindingsByItemID.filter { $0.value.requestID != binding.requestID }
        speechCaptureIDs.removeValue(forKey: binding.requestID)
        onSpeechDiscarded(binding)
    }

    private func discardOutstandingSpeechBindings() {
        var seen = Set<String>()
        let bindings = pendingLocalBindings.map(\.binding) + Array(speechBindingsByItemID.values)
        for itemID in speechBindingsByItemID.keys { rememberConsumedSpeechItem(itemID) }
        pendingLocalBindings.removeAll(keepingCapacity: false)
        speechBindingsByItemID.removeAll(keepingCapacity: false)
        speechCaptureIDs.removeAll(keepingCapacity: false)
        for binding in bindings where seen.insert(binding.requestID).inserted { onSpeechDiscarded(binding) }
    }

    private func discardPendingHints(where predicate: (SpeechHint) -> Bool) {
        let retired = pendingLocalBindings.filter(predicate)
        pendingLocalBindings.removeAll(where: predicate)
        for hint in retired { releaseBinding(hint.binding) }
    }

    private func discardLostHint(_ hint: SpeechHint) {
        discardedHintThroughFrame = max(discardedHintThroughFrame ?? 0, hint.onsetFrame)
        releaseBinding(hint.binding)
    }

    private func ownedSpeechBinding(for event: [String: Any]) -> VoiceSpeechBinding? {
        guard acceptsMicrophoneInput, let captureID = audioIO.currentCaptureID,
              let itemID = event["item_id"] as? String,
              let binding = speechBindingsByItemID[itemID],
              speechCaptureIDs[binding.requestID] == captureID else { return nil }
        return binding
    }

    private func ownsSpeechTranscript(_ event: [String: Any]) -> Bool {
        guard acceptsMicrophoneInput, let transcriptItem else { return false }
        return event["item_id"] as? String == transcriptItem.itemID
            && audioIO.currentCaptureID == transcriptItem.captureID
    }

    private func rememberConsumedSpeechItem(_ itemID: String) {
        guard consumedSpeechItemIDs.insert(itemID).inserted else { return }
        consumedSpeechItemOrder.append(itemID)
        if consumedSpeechItemOrder.count > 128 {
            consumedSpeechItemIDs.remove(consumedSpeechItemOrder.removeFirst())
        }
    }

    /// A clear acknowledges buffer bytes, not every asynchronous speech event.
    /// The serialized sample clock below also fences older speech timestamps.
    private func resetInputCapture() {
        _ = audioIO.rotateCaptureID()
        onsetDetector.reset()
        discardOutstandingSpeechBindings()
        selectionHistory.removeAll(keepingCapacity: false)
        discardedHintThroughFrame = nil
        transcriptItem = nil
        liveTranscript = ""
        dropQueuedMicrophoneAudio()
        guard isConnected else { return }
        if !inputClearPending {
            inputClearPending = true
            do { try enqueue(RealtimeWire.clearInputAudio(), kind: .clearAudio) }
            catch { failConnection(error); return }
        }
        scheduleInputClearDeadline()
    }

    private func scheduleInputClearDeadline() {
        guard inputClearPending, isMicrophoneEnabled, inputClearDeadlineTask == nil else { return }
        let connectionID = connectionAttemptID
        inputClearDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard !Task.isCancelled, let self, self.connectionAttemptID == connectionID,
                  self.inputClearPending, self.isMicrophoneEnabled else { return }
            self.inputClearDeadlineTask = nil
            self.handleMicrophoneFailure(
                VoiceSessionError.realtime("The microphone input reset was not acknowledged. Reconnect and try again."),
                resetInput: false)
        }
    }

    private func dropQueuedMicrophoneAudio() {
        let pending = outboundMessages.dropFirst(outboundHead).filter {
            if case .audio = $0.kind { return false }
            return true
        }
        outboundMessages = Array(pending)
        outboundHead = 0
        outboundByteCount = outboundMessages.reduce(0) { $0 + $1.byteCount }
    }

    private func enqueue(_ object: [String: Any], kind: OutboundMessage.Kind = .control) throws {
        guard webSocket != nil else { throw VoiceSessionError.disconnected }
        let eventType = object["type"] as? String ?? "unknown"
        let message = try RealtimeWire.encode(object)
        let bytes = message.utf8.count
        guard outboundByteCount + bytes <= 4 * 1_024 * 1_024 else {
            throw VoiceSessionError.realtime("The connection cannot keep up with outgoing audio.")
        }
        outboundMessages.append(OutboundMessage(text: message, kind: kind))
        outboundByteCount += bytes
        outboundEventCounts[eventType, default: 0] += 1
        recordOutboundSummaryIfNeeded()
        guard outboundTask == nil else { return }
        let drainID = UUID()
        outboundDrainID = drainID
        let socket = webSocket
        outboundTask = Task { [weak self, weak socket] in
            guard let self, let socket else { return }
            await self.drainOutboundMessages(socket: socket, drainID: drainID)
        }
    }

    private func drainOutboundMessages(socket: any RealtimeSocket, drainID: UUID) async {
        defer {
            if outboundDrainID == drainID {
                outboundMessages.removeAll(keepingCapacity: true)
                outboundHead = 0
                outboundByteCount = 0
                outboundTask = nil
            }
        }
        do {
            while outboundHead < outboundMessages.count {
                guard !Task.isCancelled, outboundDrainID == drainID, webSocket === socket else { return }
                let message = outboundMessages[outboundHead]
                outboundHead += 1
                outboundByteCount -= message.byteCount
                switch message.kind {
                case .audio(let captureID, let frameCount):
                    guard captureID == audioIO.currentCaptureID else { continue }
                    inputAudioFrameCount += Int64(frameCount)
                case .clearAudio:
                    inputCaptureFloorMS = (inputAudioFrameCount * 1_000 + Int64(PCMCodec.sampleRate) - 1)
                        / Int64(PCMCodec.sampleRate)
                    diagnostic("input_audio_clear_sent", fields: [
                        "frame_count": String(inputAudioFrameCount), "capture_floor_ms": String(inputCaptureFloorMS),
                    ])
                case .control:
                    break
                }
                try await send(message.text, through: socket)
                guard !Task.isCancelled, outboundDrainID == drainID, webSocket === socket else { return }
                if outboundHead >= 128, outboundHead * 2 >= outboundMessages.count {
                    outboundMessages.removeFirst(outboundHead)
                    outboundHead = 0
                }
            }
        } catch {
            guard outboundDrainID == drainID, webSocket === socket else { return }
            failConnection(error)
        }
    }

    private func send(_ message: String, through socket: any RealtimeSocket) async throws {
        var timeoutTask: Task<Void, Never>?
        defer { timeoutTask?.cancel() }
        try await withCheckedThrowingContinuation { continuation in
            let gate = WebSocketSendGate(continuation)
            socket.send(.string(message)) { @Sendable error in
                if let error { gate.resolve(.failure(error)) }
                else { gate.resolve(.success(())) }
            }
            timeoutTask = Task {
                try? await Task.sleep(for: .seconds(10))
                guard !Task.isCancelled else { return }
                guard gate.resolve(.failure(VoiceSessionError.realtime("The socket send timed out."))) else {
                    return
                }
                socket.cancel(with: .goingAway, reason: nil)
            }
        }
    }

    private func enqueueTruncation(_ cut: PlaybackCut) throws {
        try enqueue(RealtimeWire.truncate(
            itemID: cut.itemID, contentIndex: cut.contentIndex,
            audioEndMilliseconds: cut.playedMilliseconds
        ))
    }

    private func handleAudioEvent(_ event: AudioIOEvent) {
        do {
            switch event {
            case let .interruptionBegan(cut):
                isAudioReady = false
                if activeTurn?.source == .voice { retireActiveTurn() }
                if let cut { try enqueueTruncation(cut) }
                resetInputCapture()
                activity = activeTurn == nil ? .interrupted : currentTurnActivity
            case .interruptionEnded:
                guard isMicrophoneEnabled else { return }
                isAudioReady = audioIO.currentCaptureID != nil
                lastError = nil
                resetInputCapture()
                activity = currentTurnActivity
            case let .routeChanged(cut, route):
                if activeTurn?.source == .voice { retireActiveTurn() }
                if let cut { try enqueueTruncation(cut) }
                guard isMicrophoneEnabled else { return }
                isAudioReady = audioIO.currentCaptureID != nil
                audioRouteSummary = route.summary
                lastError = nil
                resetInputCapture()
                activity = currentTurnActivity
            case let .configurationChangeBegan(cut):
                isAudioReady = false
                if activeTurn?.source == .voice { retireActiveTurn() }
                if let cut { try enqueueTruncation(cut) }
                resetInputCapture()
                activity = activeTurn == nil ? .reconfiguringAudio : currentTurnActivity
            case let .configurationChangeEnded(route):
                guard isMicrophoneEnabled else { return }
                isAudioReady = audioIO.currentCaptureID != nil
                audioRouteSummary = route.summary
                lastError = nil
                resetInputCapture()
                activity = currentTurnActivity
            case let .playbackFinished(itemID):
                guard var turn = activeTurn, turn.phase == .final, turn.source == .voice,
                      turn.outputItemID == itemID
                else {
                    diagnostic("playback_completion_ignored", level: .warning, fields: ["item_id": itemID])
                    return
                }
                diagnostic("final_playback_completed", correlationID: turn.requestID, fields: [
                    "item_id": itemID, "response_id": turn.responseID ?? "unknown",
                ])
                receivedFirstOutputAudio = false
                turn.playbackFinished = true
                if turn.providerResponsePending {
                    activeTurn = turn
                    activity = .delivering
                } else {
                    activeTurn = nil
                    activity = isMicrophoneEnabled ? .listening : .ready
                }
            case let .failure(_, cut):
                if let cut { try enqueueTruncation(cut) }
                handleMicrophoneFailure(VoiceSessionError.microphoneUnavailable)
            }
        } catch { handleMicrophoneFailure(error) }
    }

    private var currentTurnActivity: RealtimeActivity {
        if let turn = activeTurn {
            return turn.phase == .final ? .delivering : .waitingForAstra
        }
        return isMicrophoneEnabled ? .listening : (isConnected ? .ready : .idle)
    }

    private func handleMicrophoneFailure(_ error: Error, resetInput: Bool = true) {
        diagnostic("microphone_failed", level: .error, fields: [
            "error_type": String(describing: type(of: error)),
        ])
        if activeTurn?.source == .voice { retireActiveTurn() }
        invalidateAudioCapture()
        audioIO.stop()
        isMicrophoneEnabled = false
        inputClearDeadlineTask?.cancel()
        inputClearDeadlineTask = nil
        if resetInput { resetInputCapture() }
        else {
            onsetDetector.reset()
            discardOutstandingSpeechBindings()
            dropQueuedMicrophoneAudio()
        }
        lastError = (error as? LocalizedError)?.errorDescription ?? "Microphone unavailable."
        activity = isConnected ? currentTurnActivity : .failed(lastError ?? "Microphone unavailable")
    }

    private func failTurn(_ error: Error, generation failedGeneration: Int) {
        guard let turn = activeTurn, turn.generation == failedGeneration else {
            diagnostic("turn_failure_ignored", level: .warning, fields: [
                "generation": String(failedGeneration), "reason": "stale",
            ])
            return
        }
        sceneExecutionTask?.cancel()
        sceneExecutionTask = nil
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        do {
            if turn.providerResponsePending {
                try enqueue(RealtimeWire.cancelResponse(responseID: turn.responseID))
            }
            if let cut = audioIO.interruptPlayback() { try enqueueTruncation(cut) }
        } catch {
            diagnostic("turn_failure_cleanup_failed", level: .warning, correlationID: turn.requestID)
        }
        if let binding = turn.binding { releaseBinding(binding) }
        activeTurn = nil
        lastError = (error as? LocalizedError)?.errorDescription ?? "The request failed."
        diagnostic("turn_failed", level: .error, correlationID: turn.requestID, fields: [
            "generation": String(turn.generation), "error_type": String(describing: type(of: error)),
        ])
        activity = isMicrophoneEnabled ? .listening : .ready
    }

    private func failConnection(_ error: Error) {
        guard isConnecting || isConnected else { return }
        let message = (error as? LocalizedError)?.errorDescription ?? "The conversation disconnected."
        logger.error("Realtime session failed (details withheld; see structured diagnostics)")
        diagnostic("connection_failed", level: .error, fields: [
            "error_type": String(describing: type(of: error)),
        ])
        lastError = message
        isConnecting = false
        isConnected = false
        resolveConnectWaiters(false)
        resetTransport()
        activity = .failed(message)
    }

    private func resolveConnectWaiters(_ result: Bool) {
        let waiters = connectWaiters
        connectWaiters.removeAll(keepingCapacity: false)
        for waiter in waiters { waiter.resume(returning: result) }
    }

    private func resetTransport() {
        microphoneEnableID = UUID()
        invalidateAudioCapture()
        inputClearDeadlineTask?.cancel()
        inputClearDeadlineTask = nil
        inputClearPending = false
        inputAudioFrameCount = 0
        inputCaptureFloorMS = 0
        selectionHistory.removeAll(keepingCapacity: false)
        discardedHintThroughFrame = nil
        lastAdmittedSpeechStartMS = nil
        transcriptItem = nil
        sceneExecutionTask?.cancel()
        sceneExecutionTask = nil
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        receiveTask?.cancel()
        receiveTask = nil
        handshakeTimeoutTask?.cancel()
        handshakeTimeoutTask = nil
        outboundTask?.cancel()
        outboundTask = nil
        outboundDrainID = UUID()
        outboundMessages.removeAll(keepingCapacity: false)
        outboundHead = 0
        outboundByteCount = 0
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        audioIO.stop()
        isMicrophoneEnabled = false
        didSendSessionConfiguration = false
        onsetDetector.reset()
        discardOutstandingSpeechBindings()
        consumedSpeechItemIDs.removeAll(keepingCapacity: false)
        consumedSpeechItemOrder.removeAll(keepingCapacity: false)
        pendingCalls.removeAll(keepingCapacity: false)
        activeTurn = nil
        receivedFirstOutputAudio = false
        socketEventCounts.removeAll(keepingCapacity: false)
        socketEventBytes = 0
        lastSocketSummaryAt = Date()
        outboundEventCounts.removeAll(keepingCapacity: false)
        lastOutboundSummaryAt = Date()
        executedCallIDs.removeAll(keepingCapacity: false)
        microphoneBufferCount = 0
        microphoneFrameCount = 0
        lastMicrophoneSummaryAt = Date()
    }

    private func scheduleResponseDeadline(for turn: ActiveTurn) {
        responseDeadlineTask?.cancel()
        let expectedGeneration = turn.generation
        let expectedPhase = turn.phase
        responseDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(25))
            guard !Task.isCancelled, let self, let current = self.activeTurn,
                  current.generation == expectedGeneration, current.phase == expectedPhase,
                  current.providerResponsePending
            else { return }
            self.diagnostic("response_timeout", level: .error, correlationID: current.requestID, fields: [
                "generation": String(current.generation), "phase": current.phase.rawValue,
            ])
            try? self.enqueue(RealtimeWire.cancelResponse(responseID: current.responseID))
            self.failTurn(
                VoiceSessionError.realtime("The response timed out."),
                generation: current.generation
            )
        }
    }

    private func generation(fromEventID eventID: String?) -> Int? {
        guard let eventID, eventID.hasPrefix("turn_") else { return nil }
        return Int(eventID.dropFirst(5).prefix { $0.isNumber })
    }

    private func diagnostic(
        _ name: String, level: DiagnosticLevel = .info,
        correlationID: String? = nil, fields: [String: String] = [:]
    ) {
        DiagnosticsLog.shared.record(
            name, component: "realtime.session", level: level,
            correlationID: correlationID ?? sessionCorrelationID, fields: fields
        )
    }

    private func milliseconds(since date: Date) -> String {
        String(Int(Date().timeIntervalSince(date) * 1_000))
    }

    private func recordSocketEvent(type: String, bytes: Int) {
        let highFrequency: Set<String> = [
            "conversation.item.input_audio_transcription.delta",
            "response.output_audio.delta", "response.output_audio_transcript.delta",
            "response.output_text.delta",
        ]
        if !highFrequency.contains(type) {
            diagnostic("realtime_event_received", fields: [
                "event_type": type, "message_bytes": String(bytes),
            ])
        }
        socketEventCounts[type, default: 0] += 1
        socketEventBytes += bytes
        guard Date().timeIntervalSince(lastSocketSummaryAt) >= 1 else { return }
        diagnostic("realtime_receive_summary", fields: [
            "event_counts": socketEventCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: ","),
            "message_bytes": String(socketEventBytes),
        ])
        socketEventCounts.removeAll(keepingCapacity: true)
        socketEventBytes = 0
        lastSocketSummaryAt = Date()
    }

    private func recordOutboundSummaryIfNeeded() {
        guard Date().timeIntervalSince(lastOutboundSummaryAt) >= 1 else { return }
        diagnostic("realtime_send_queue_summary", fields: [
            "event_counts": outboundEventCounts.sorted { $0.key < $1.key }
                .map { "\($0.key):\($0.value)" }.joined(separator: ","),
            "queued_messages": String(outboundMessages.count - outboundHead),
            "queued_bytes": String(outboundByteCount),
        ])
        outboundEventCounts.removeAll(keepingCapacity: true)
        lastOutboundSummaryAt = Date()
    }
}
