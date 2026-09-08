import Foundation
import Observation
import os

@MainActor
@Observable
final class VoiceSession {
    private(set) var state: VoiceSessionState = .idle
    private(set) var liveTranscript = ""
    private(set) var lastError: String?
    private(set) var troubleshootingText: String?
    private(set) var audioRouteSummary: String?

    var statusText: String { state.statusText }
    var isActive: Bool {
        switch state {
        case .idle, .failed: false
        default: true
        }
    }

    @ObservationIgnored private let logger = Logger(
        subsystem: "com.astra.spatialdemo",
        category: "voice-session"
    )
    /// `nil` means the user attempted to point but no unambiguous target could
    /// be locked. An empty array is a deliberate unselected/global request.
    @ObservationIgnored private let selectionProvider: @MainActor () -> [String]?
    @ObservationIgnored private let onSpeechStarted: @MainActor (VoiceSpeechBinding) -> Void
    @ObservationIgnored private let onFinalTranscript: @MainActor (VoiceUtterance) -> Void
    @ObservationIgnored private let onSpeechDiscarded: @MainActor (VoiceSpeechBinding) -> Void
    @ObservationIgnored private let narrationGate: @MainActor (VoiceNarrationCue) -> Bool
    @ObservationIgnored private let urlSession: URLSession

    @ObservationIgnored private var webSocket: URLSessionWebSocketTask?
    @ObservationIgnored private var receiveTask: Task<Void, Never>?
    @ObservationIgnored private var outboundTask: Task<Void, Never>?
    @ObservationIgnored private var outboundMessages: [String] = []
    @ObservationIgnored private var outboundHead = 0
    @ObservationIgnored private var outboundByteCount = 0
    @ObservationIgnored private var startRequested = false
    @ObservationIgnored private var didSendSessionConfiguration = false
    @ObservationIgnored private var audioStarted = false
    @ObservationIgnored private var onsetDetector = VoiceOnsetDetector()
    @ObservationIgnored private var pendingLocalBindings: [VoiceSpeechBinding] = []
    @ObservationIgnored private var speechBindingsByItemID: [String: VoiceSpeechBinding] = [:]
    @ObservationIgnored private var activeNarration: VoiceNarrationCue?

    @ObservationIgnored private lazy var audioIO = AudioIOController(
        onMicrophonePCM: { [weak self] data in
            Task { @MainActor [weak self] in
                self?.enqueueMicrophonePCM(data)
            }
        },
        onMicrophoneFailure: { [weak self] message in
            Task { @MainActor [weak self] in
                self?.fail(VoiceSessionError.realtime("Microphone conversion failed: \(message)"))
            }
        },
        onEvent: { [weak self] event in
            self?.handleAudioEvent(event)
        }
    )

    init(
        selectionProvider: @escaping @MainActor () -> [String]?,
        onSpeechStarted: @escaping @MainActor (VoiceSpeechBinding) -> Void,
        onFinalTranscript: @escaping @MainActor (VoiceUtterance) -> Void,
        onSpeechDiscarded: @escaping @MainActor (VoiceSpeechBinding) -> Void = { _ in },
        narrationGate: @escaping @MainActor (VoiceNarrationCue) -> Bool
    ) {
        self.selectionProvider = selectionProvider
        self.onSpeechStarted = onSpeechStarted
        self.onFinalTranscript = onFinalTranscript
        self.onSpeechDiscarded = onSpeechDiscarded
        self.narrationGate = narrationGate
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = true
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 60 * 60
        urlSession = URLSession(configuration: configuration)

        #if targetEnvironment(simulator)
        troubleshootingText = "The iOS Simulator may have no usable microphone route. Use a physical iPhone or iPad for voice acceptance."
        #endif
    }

    /// Starts microphone capture only after an explicit app/user action.
    func start(configuration: VoiceSessionConfiguration) async {
        guard !isActive else { return }
        resetForStart()
        startRequested = true
        state = .requestingPermission

        let permissionGranted = await AudioIOController.requestMicrophonePermission()
        guard startRequested else { return }
        guard permissionGranted else {
            fail(VoiceSessionError.microphoneDenied)
            return
        }

        do {
            state = .fetchingCredential
            let credential = try await fetchClientSecret(configuration: configuration)
            guard startRequested else { return }
            guard credential.clientSecret.expiresAt > Date().timeIntervalSince1970 + 5 else {
                throw VoiceSessionError.credentialExpired
            }
            try connectRealtime(
                model: credential.model,
                clientSecret: credential.clientSecret.value
            )
        } catch {
            fail(error)
        }
    }

    func stop() {
        startRequested = false
        tearDownTransport()
        state = .idle
        liveTranscript = ""
        lastError = nil
    }

    /// Requests speech from Realtime only for a still-current, receipt-backed
    /// explanation authored by Astra.
    func speak(_ cue: VoiceNarrationCue) async {
        guard webSocket != nil else {
            fail(VoiceSessionError.disconnected)
            return
        }
        guard narrationGate(cue) else {
            logger.notice("Suppressed obsolete narration for request \(cue.requestID, privacy: .private(mask: .hash))")
            return
        }

        await cancelCurrentNarration()
        activeNarration = cue
        state = .speaking
        do {
            try enqueue(RealtimeWire.speak(cue))
        } catch {
            fail(error)
        }
    }

    /// Call after an intent epoch, node, or animation prerequisite changes.
    func invalidateNarration() async {
        guard let activeNarration, !narrationGate(activeNarration) else { return }
        await cancelCurrentNarration()
        if audioStarted { state = .listening }
    }

    private func resetForStart() {
        tearDownTransport()
        liveTranscript = ""
        lastError = nil
        didSendSessionConfiguration = false
        onsetDetector.reset()
        pendingLocalBindings.removeAll(keepingCapacity: false)
        speechBindingsByItemID.removeAll(keepingCapacity: false)
        activeNarration = nil
    }

    private func fetchClientSecret(
        configuration: VoiceSessionConfiguration
    ) async throws -> RealtimeClientSecretResponse {
        guard let scheme = configuration.backendBaseURL.scheme,
              scheme == "http" || scheme == "https"
        else { throw VoiceSessionError.invalidBackendURL }

        let endpoint = configuration.backendBaseURL
            .appending(path: "realtime")
            .appending(path: "client-secret")
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = configuration.sessionAuthToken, !token.isEmpty {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "sessionId": configuration.sessionID,
        ])

        let (data, response) = try await urlSession.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw VoiceSessionError.malformedCredentialResponse
        }
        guard (200..<300).contains(httpResponse.statusCode) else {
            let detail = String(data: data, encoding: .utf8) ?? "No response body"
            throw VoiceSessionError.backend(httpResponse.statusCode, String(detail.prefix(500)))
        }
        do {
            let decoded = try JSONDecoder().decode(RealtimeClientSecretResponse.self, from: data)
            guard !decoded.clientSecret.value.isEmpty, !decoded.model.isEmpty else {
                throw VoiceSessionError.malformedCredentialResponse
            }
            return decoded
        } catch let error as VoiceSessionError {
            throw error
        } catch {
            throw VoiceSessionError.malformedCredentialResponse
        }
    }

    private func connectRealtime(model: String, clientSecret: String) throws {
        var components = URLComponents()
        components.scheme = "wss"
        components.host = "api.openai.com"
        components.path = "/v1/realtime"
        components.queryItems = [URLQueryItem(name: "model", value: model)]
        guard let url = components.url else { throw VoiceSessionError.disconnected }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(clientSecret)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 30
        let webSocket = urlSession.webSocketTask(with: request)
        webSocket.maximumMessageSize = 16 * 1_024 * 1_024
        self.webSocket = webSocket
        state = .connecting
        webSocket.resume()
        beginReceiving(from: webSocket)
    }

    private func beginReceiving(from webSocket: URLSessionWebSocketTask) {
        receiveTask?.cancel()
        receiveTask = Task { [weak self, weak webSocket] in
            guard let webSocket else { return }
            do {
                while !Task.isCancelled {
                    let message = try await webSocket.receive()
                    guard let text = RealtimeWire.text(from: message) else { continue }
                    try self?.handleRealtimeEvent(text)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.startRequested else { return }
                self.fail(error)
            }
        }
    }

    private func handleRealtimeEvent(_ text: String) throws {
        guard let data = text.data(using: .utf8),
              let event = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = event["type"] as? String
        else { return }

        switch type {
        case "session.created":
            guard !didSendSessionConfiguration else { return }
            didSendSessionConfiguration = true
            try enqueue(RealtimeWire.sessionUpdate())

        case "session.updated":
            guard startRequested, !audioStarted else { return }
            let route = try audioIO.start()
            audioStarted = true
            state = .listening
            audioRouteSummary = route.summary
            if !route.voiceProcessingEnabled {
                troubleshootingText = "System voice processing is unavailable on the current route. Headphones reduce speaker-to-microphone echo for this WebSocket baseline."
            }

        case "input_audio_buffer.speech_started":
            liveTranscript = ""
            bindRemoteSpeechItem(event)
            let cut = audioIO.interruptPlayback()
            activeNarration = nil
            if let cut { try enqueueTruncation(cut) }
            if audioStarted { state = .listening }

        case "conversation.item.input_audio_transcription.delta":
            if let delta = event["delta"] as? String { liveTranscript += delta }

        case "conversation.item.input_audio_transcription.completed":
            guard let itemID = event["item_id"] as? String else {
                discardOutstandingSpeechBindings()
                troubleshootingText = "A transcript arrived without an unambiguous local speech-start selection. It was not sent to Astra."
                return
            }
            guard let binding = speechBindingsByItemID.removeValue(forKey: itemID) else {
                troubleshootingText = "A transcript arrived without an unambiguous local speech-start selection. It was not sent to Astra."
                return
            }
            guard let transcript = event["transcript"] as? String else {
                onSpeechDiscarded(binding)
                troubleshootingText = "Realtime returned a transcript event without text. No request was sent to Astra."
                return
            }
            let text = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                onSpeechDiscarded(binding)
                return
            }
            liveTranscript = text
            onFinalTranscript(VoiceUtterance(
                requestID: binding.requestID,
                text: text,
                nodeIDs: binding.nodeIDs,
                beganAt: binding.beganAt
            ))

        case "conversation.item.input_audio_transcription.failed":
            if let itemID = event["item_id"] as? String,
               let binding = speechBindingsByItemID.removeValue(forKey: itemID)
            {
                onSpeechDiscarded(binding)
            }
            troubleshootingText = "Realtime could not transcribe that turn. No request was sent to Astra."

        case "response.output_audio.delta":
            try handleAudioDelta(event)

        case "response.output_audio.done":
            if let itemID = event["item_id"] as? String {
                audioIO.markOutputComplete(itemID: itemID)
            }

        case "response.cancelled":
            activeNarration = nil
            if audioStarted { state = .listening }

        case "error":
            let errorObject = event["error"] as? [String: Any]
            let message = errorObject?["message"] as? String
                ?? event["message"] as? String
                ?? "Unknown Realtime error"
            throw VoiceSessionError.realtime(message)

        default:
            break
        }
    }

    private func handleAudioDelta(_ event: [String: Any]) throws {
        guard let cue = activeNarration else {
            try enqueue(RealtimeWire.cancelResponse())
            return
        }
        guard narrationGate(cue) else {
            Task { await invalidateNarration() }
            return
        }
        guard let encoded = event["delta"] as? String,
              let data = Data(base64Encoded: encoded),
              let itemID = event["item_id"] as? String
        else { return }
        let contentIndex = event["content_index"] as? Int ?? 0
        try audioIO.enqueuePlayback(data, itemID: itemID, contentIndex: contentIndex)
        state = .speaking
    }

    private func enqueueMicrophonePCM(_ data: Data) {
        guard audioStarted, startRequested else { return }
        if onsetDetector.process(pcm16: data) == .began {
            if let nodeIDs = selectionProvider() {
                let binding = VoiceSpeechBinding(
                    requestID: UUID().uuidString,
                    nodeIDs: nodeIDs,
                    beganAt: Date()
                )
                pendingLocalBindings.append(binding)
                if pendingLocalBindings.count > 3 {
                    let overflowCount = pendingLocalBindings.count - 3
                    let overflow = pendingLocalBindings.prefix(overflowCount)
                    pendingLocalBindings.removeFirst(overflowCount)
                    for binding in overflow { onSpeechDiscarded(binding) }
                }
                onSpeechStarted(binding)
            } else {
                troubleshootingText = "Speech began while the pointing target was ambiguous. The turn will not be sent to Astra."
            }
        }
        do {
            try enqueue(RealtimeWire.appendAudio(data))
        } catch {
            fail(error)
        }
    }

    private func bindRemoteSpeechItem(_ event: [String: Any]) {
        guard let itemID = event["item_id"] as? String else {
            discardPendingLocalBindings()
            troubleshootingText = "Realtime reported speech without an item ID. The turn will not be sent to Astra."
            return
        }
        let now = Date()
        let expired = pendingLocalBindings.filter { now.timeIntervalSince($0.beganAt) > 5 }
        pendingLocalBindings.removeAll { now.timeIntervalSince($0.beganAt) > 5 }
        for binding in expired { onSpeechDiscarded(binding) }
        guard pendingLocalBindings.count == 1 else {
            discardPendingLocalBindings()
            troubleshootingText = "Cloud speech onset had no single recent local onset. The turn will not inherit the current selection."
            return
        }
        let binding = pendingLocalBindings.removeFirst()
        if let replaced = speechBindingsByItemID.updateValue(binding, forKey: itemID) {
            onSpeechDiscarded(replaced)
        }
    }

    private func discardPendingLocalBindings() {
        let bindings = pendingLocalBindings
        pendingLocalBindings.removeAll(keepingCapacity: true)
        for binding in bindings { onSpeechDiscarded(binding) }
    }

    private func discardOutstandingSpeechBindings() {
        var discardedRequestIDs = Set<String>()
        let pending = pendingLocalBindings
        let bound = Array(speechBindingsByItemID.values)
        pendingLocalBindings.removeAll(keepingCapacity: true)
        speechBindingsByItemID.removeAll(keepingCapacity: true)
        for binding in pending where discardedRequestIDs.insert(binding.requestID).inserted {
            onSpeechDiscarded(binding)
        }
        for binding in bound where discardedRequestIDs.insert(binding.requestID).inserted {
            onSpeechDiscarded(binding)
        }
    }

    private func enqueue(_ object: [String: Any]) throws {
        let message = try RealtimeWire.encode(object)
        let messageBytes = message.utf8.count
        guard outboundByteCount + messageBytes <= 4 * 1_024 * 1_024 else {
            throw VoiceSessionError.realtime("The voice connection cannot keep up with microphone audio.")
        }
        outboundMessages.append(message)
        outboundByteCount += messageBytes
        guard outboundTask == nil else { return }
        outboundTask = Task { [weak self] in
            await self?.drainOutboundMessages()
        }
    }

    private func drainOutboundMessages() async {
        defer {
            outboundMessages.removeAll(keepingCapacity: true)
            outboundHead = 0
            outboundByteCount = 0
            outboundTask = nil
        }
        do {
            while outboundHead < outboundMessages.count {
                guard !Task.isCancelled, let webSocket else { return }
                let message = outboundMessages[outboundHead]
                outboundHead += 1
                outboundByteCount -= message.utf8.count
                try await webSocket.send(.string(message))
                if outboundHead >= 128, outboundHead * 2 >= outboundMessages.count {
                    outboundMessages.removeFirst(outboundHead)
                    outboundHead = 0
                }
            }
        } catch {
            guard startRequested else { return }
            fail(error)
        }
    }

    private func cancelCurrentNarration() async {
        guard activeNarration != nil else { return }
        do {
            try enqueue(RealtimeWire.cancelResponse())
            if let cut = audioIO.interruptPlayback() {
                try enqueueTruncation(cut)
            }
        } catch {
            fail(error)
        }
        activeNarration = nil
    }

    private func enqueueTruncation(_ cut: PlaybackCut) throws {
        try enqueue(RealtimeWire.truncate(
            itemID: cut.itemID,
            contentIndex: cut.contentIndex,
            audioEndMilliseconds: cut.playedMilliseconds
        ))
    }

    private func handleAudioEvent(_ event: AudioIOEvent) {
        do {
            switch event {
            case let .interruptionBegan(cut):
                if let cut { try enqueueTruncation(cut) }
                state = .interrupted
            case .interruptionEnded:
                state = .listening
            case let .routeChanged(cut, route):
                if let cut { try enqueueTruncation(cut) }
                audioRouteSummary = route.summary
                state = .listening
            case let .configurationChangeBegan(cut):
                if let cut { try enqueueTruncation(cut) }
                state = .reconfiguringAudio
            case let .configurationChangeEnded(route):
                audioRouteSummary = route.summary
                state = .listening
            case .playbackFinished:
                activeNarration = nil
                if audioStarted { state = .listening }
            case let .failure(message):
                throw VoiceSessionError.realtime(message)
            }
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        logger.error("Voice session failed: \(message, privacy: .public)")
        lastError = message
        if troubleshootingText == nil {
            troubleshootingText = "Check the backend URL, local-network access, microphone permission, and the current audio route."
        }
        startRequested = false
        tearDownTransport()
        state = .failed(message)
    }

    private func tearDownTransport() {
        discardOutstandingSpeechBindings()
        receiveTask?.cancel()
        receiveTask = nil
        outboundTask?.cancel()
        outboundTask = nil
        outboundMessages.removeAll(keepingCapacity: false)
        outboundHead = 0
        outboundByteCount = 0
        webSocket?.cancel(with: .goingAway, reason: nil)
        webSocket = nil
        if audioStarted { audioIO.stop() }
        audioStarted = false
        didSendSessionConfiguration = false
        onsetDetector.reset()
        pendingLocalBindings.removeAll(keepingCapacity: false)
        speechBindingsByItemID.removeAll(keepingCapacity: false)
        activeNarration = nil
    }
}
