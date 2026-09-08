import Foundation
import Testing

/// A controllable boundary queue. The deadline reports a missing event; it never
/// advances the production conversation or substitutes for a synchronization point.
@MainActor
final class TestMailbox<Value: Sendable> {
    private var buffered: [Value] = []
    private var waiters: [(UUID, CheckedContinuation<Value, Error>)] = []
    private var closed = false

    func send(_ value: Value) {
        guard !closed else { return }
        if waiters.isEmpty { buffered.append(value) }
        else { waiters.removeFirst().1.resume(returning: value) }
    }

    func next(timeout: Duration? = .seconds(3)) async throws -> Value {
        if !buffered.isEmpty { return buffered.removeFirst() }
        guard !closed else { throw TestBoundaryError.closed }
        let id = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            waiters.append((id, continuation))
            guard let timeout else { return }
            Task { [weak self] in
                try? await Task.sleep(for: timeout)
                guard let self, let index = self.waiters.firstIndex(where: { $0.0 == id }) else { return }
                self.waiters.remove(at: index).1.resume(throwing: TestBoundaryError.eventDeadline)
            }
        }
    }

    func close() {
        closed = true
        buffered.removeAll()
        let pending = waiters
        waiters.removeAll()
        for (_, continuation) in pending { continuation.resume(throwing: TestBoundaryError.closed) }
    }
}

enum TestBoundaryError: Error { case closed, eventDeadline, audioUnavailable }

struct TestWireEvent: Sendable {
    let data: Data

    init(_ object: [String: Any]) throws {
        data = try JSONSerialization.data(withJSONObject: object)
    }

    var object: [String: Any] {
        (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    var type: String { object["type"] as? String ?? "" }
    var response: [String: Any] { object["response"] as? [String: Any] ?? [:] }
    var metadata: [String: Any] { response["metadata"] as? [String: Any] ?? [:] }
    var phase: String { metadata["phase"] as? String ?? "" }
    var requestID: String { metadata["request_id"] as? String ?? "" }
    var item: [String: Any] { object["item"] as? [String: Any] ?? [:] }
    var callID: String { item["call_id"] as? String ?? "" }

    func decodedToolResult() throws -> RealtimeSceneToolResult {
        let text = try #require(item["output"] as? String)
        return try JSONDecoder().decode(RealtimeSceneToolResult.self, from: Data(text.utf8))
    }
}

@MainActor
final class TestRealtimeSocket: RealtimeSocket {
    private struct Incoming: Sendable {
        let sequence: Int
        let message: URLSessionWebSocketTask.Message
    }
    var maximumMessageSize = 0
    private(set) var sent: [TestWireEvent] = []
    private(set) var receiveCount = 0
    private(set) var resumeCount = 0
    private(set) var cancelCount = 0
    var acknowledgesClears = true
    private let inbound = TestMailbox<Incoming>()
    private let sentSignal = TestMailbox<Int>()
    private let receiveSignal = TestMailbox<Int>()
    private var emittedSequence = 0
    private var deliveredSequence = 0
    private var processedSequence = 0

    func resume() {
        resumeCount += 1
        emit(["type": "session.created"])
    }

    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        cancelCount += 1
        inbound.close()
        sentSignal.close()
        receiveSignal.close()
    }

    func receive() async throws -> URLSessionWebSocketTask.Message {
        receiveCount += 1
        processedSequence = deliveredSequence
        receiveSignal.send(processedSequence)
        // A connected socket may be idle indefinitely. Only the test's explicit
        // event expectations time out; an absent fixture event is not a server failure.
        let incoming = try await inbound.next(timeout: nil)
        deliveredSequence = incoming.sequence
        return incoming.message
    }

    func send(_ message: URLSessionWebSocketTask.Message, completionHandler: @escaping @Sendable (Error?) -> Void) {
        do {
            let text = try #require(RealtimeWire.text(from: message))
            let object = try #require(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
            let event = try TestWireEvent(object)
            sent.append(event)
            sentSignal.send(sent.count)
            completionHandler(nil)
            if event.type == "session.update" { emit(["type": "session.updated"]) }
            if event.type == "input_audio_buffer.clear", acknowledgesClears {
                emit(["type": "input_audio_buffer.cleared"])
            }
        } catch { completionHandler(error) }
    }

    @discardableResult
    func emit(_ event: [String: Any]) -> Int {
        emittedSequence += 1
        do {
            inbound.send(Incoming(sequence: emittedSequence, message: .data(try JSONSerialization.data(withJSONObject: event))))
        }
        catch { Issue.record(error) }
        return emittedSequence
    }

    /// The next receive invocation proves the preceding event passed through the
    /// real session handler. It does not depend on executor scheduling or delays.
    func feed(_ event: [String: Any]) async throws {
        let sequence = emit(event)
        while processedSequence < sequence { _ = try await receiveSignal.next() }
    }

    func nextSent(after index: Int = 0, matching predicate: (TestWireEvent) -> Bool) async throws -> TestWireEvent {
        while true {
            if let event = sent.dropFirst(index).first(where: predicate) { return event }
            _ = try await sentSignal.next()
        }
    }

    func barrier() async throws {
        // Unknown provider events are deliberately ignored by the production
        // handler; their only role here is to join its serial receive loop.
        try await feed(["type": "test.transport_barrier"])
    }
}

@MainActor
final class TestRealtimeAudio: RealtimeAudioIO {
    private(set) var currentCaptureID: UUID?
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var playback: [(Data, String)] = []
    private(set) var completedItemIDs: [String] = []
    var startError: (any Error)?
    var eventSink: (@MainActor (AudioIOEvent) -> Void)?
    private var captureContinuation: AsyncThrowingStream<MicrophoneChunk, Error>.Continuation?
    private let stopSignal = TestMailbox<Int>()
    var playbackCut: PlaybackCut?

    static let route = AudioRouteReport(
        inputSampleRate: 24_000, inputChannelCount: 1,
        inputPortTypes: ["test-input"], outputPortTypes: ["test-output"], voiceProcessingEnabled: true
    )

    func start() throws -> AudioCapture {
        if let startError { throw startError }
        startCount += 1
        let pair = AsyncThrowingStream<MicrophoneChunk, Error>.makeStream()
        captureContinuation = pair.continuation
        currentCaptureID = UUID()
        return AudioCapture(sessionID: UUID(), route: Self.route, stream: pair.stream)
    }

    func rotateCaptureID() -> UUID? {
        guard currentCaptureID != nil else { return nil }
        currentCaptureID = UUID()
        return currentCaptureID
    }

    func stop() {
        stopCount += 1
        currentCaptureID = nil
        captureContinuation?.finish()
        captureContinuation = nil
        stopSignal.send(stopCount)
    }

    func enqueuePlayback(_ data: Data, itemID: String, contentIndex: Int) throws {
        guard currentCaptureID != nil else { throw TestBoundaryError.audioUnavailable }
        playback.append((data, itemID))
    }

    func markOutputComplete(itemID: String) { completedItemIDs.append(itemID) }
    func interruptPlayback() -> PlaybackCut? {
        defer { playbackCut = nil }
        return playbackCut
    }

    func emitPCM(_ data: Data, captureID: UUID? = nil) throws {
        let id = try #require(captureID ?? currentCaptureID)
        captureContinuation?.yield(MicrophoneChunk(captureID: id, data: data))
    }

    func failCapture() { captureContinuation?.finish(throwing: VoiceSessionError.microphoneUnavailable) }

    func waitForStop(after count: Int) async throws {
        while stopCount <= count { _ = try await stopSignal.next() }
    }

    func close() { stop(); stopSignal.close() }
}

@MainActor
final class TestSceneExecutor {
    private(set) var requests: [RealtimeSceneToolRequest] = []
    private var results: [String: CheckedContinuation<RealtimeSceneToolResult, Never>] = [:]
    private let started = TestMailbox<RealtimeSceneToolRequest>()

    func execute(_ request: RealtimeSceneToolRequest) async -> RealtimeSceneToolResult {
        requests.append(request)
        return await withCheckedContinuation { continuation in
            results[request.requestID] = continuation
            started.send(request)
        }
    }

    func nextRequest() async throws -> RealtimeSceneToolRequest { try await started.next() }

    func resolve(_ request: RealtimeSceneToolRequest, status: String = "completed", installed: Bool = false) {
        results.removeValue(forKey: request.requestID)?.resume(returning: RealtimeSceneToolResult(
            status: status, requestID: request.requestID, sceneID: "scene-test", revision: installed ? 1 : 0,
            intentEpoch: 1, proposalRequestIDs: installed ? ["patch-\(request.requestID)"] : [],
            explanation: status == "completed" ? "The selected component is ready." : nil,
            error: status == "cancelled" ? "The request was cancelled." : nil
        ))
    }

    func close() {
        for request in requests { resolve(request, status: "cancelled") }
        started.close()
    }
}

@MainActor
final class RealtimeFixture {
    let socket = TestRealtimeSocket()
    let audio = TestRealtimeAudio()
    let executor = TestSceneExecutor()
    private(set) var credentialCount = 0
    private(set) var socketCount = 0
    private(set) var bindings: [VoiceSpeechBinding] = []
    private(set) var discardedBindings: [VoiceSpeechBinding] = []
    var permissionGranted = true
    var selectedNodeIDs = ["component-a"]

    lazy var session = RealtimeSession(
        selectionProvider: { [weak self] in self?.selectedNodeIDs },
        onSpeechStarted: { [weak self] in self?.bindings.append($0) },
        onSpeechDiscarded: { [weak self] in self?.discardedBindings.append($0) },
        executeScene: { [executor] in await executor.execute($0) },
        selectionSnapshotProvider: { [weak self] in self?.selectedNodeIDs },
        dependencies: RealtimeDependencies(
            fetchCredentialData: { [weak self] request in
                self?.credentialCount += 1
                let url = try #require(request.url)
                let data = try JSONSerialization.data(withJSONObject: [
                    "clientSecret": ["value": "test-credential", "expires_at": Date().timeIntervalSince1970 + 3_600],
                    "model": "test-realtime"
                ])
                let response = try #require(HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
                return (data, response)
            },
            makeSocket: { [weak self, socket] _ in self?.socketCount += 1; return socket },
            makeAudioIO: { [audio] sink in audio.eventSink = sink; return audio },
            requestMicrophonePermission: { [weak self] in self?.permissionGranted ?? false }
        )
    )

    func connect() async throws {
        let configuration = VoiceSessionConfiguration(backendBaseURL: URL(string: "https://test.invalid")!, sessionID: "test")
        let connected = await session.connect(configuration: configuration)
        #expect(connected)
        #expect(socketCount == 1)
        #expect(credentialCount == 1)
    }

    func enableMicrophone() async throws {
        let offset = socket.sent.count
        let enabled = await session.setMicrophoneEnabled(true)
        #expect(enabled)
        _ = try await socket.nextSent(after: offset) { $0.type == "input_audio_buffer.clear" }
        try await socket.barrier()
    }

    func sendPCM(frames: Int = 1_024, amplitude: Int16 = 8_000, captureID: UUID? = nil) async throws {
        let offset = socket.sent.count
        try audio.emitPCM(Self.pcm(frames: frames, amplitude: amplitude), captureID: captureID)
        _ = try await socket.nextSent(after: offset) { $0.type == "input_audio_buffer.append" }
    }

    func beginSpeech(itemID: String, audioStartMilliseconds: Int = 0) async throws {
        // Enough real 24 kHz input for the production local onset detector.
        try await sendPCM(frames: 1_024)
        try await sendPCM(frames: 1_024)
        try await socket.feed(["type": "input_audio_buffer.speech_started", "item_id": itemID, "audio_start_ms": audioStartMilliseconds])
    }

    func commitSpeech(itemID: String, after offset: Int = 0) async throws -> TestWireEvent {
        try await socket.feed(["type": "input_audio_buffer.committed", "item_id": itemID])
        return try await socket.nextSent(after: offset) { $0.type == "response.create" && $0.phase == "tool" }
    }

    func completeTool(_ creation: TestWireEvent, callID: String) async throws -> RealtimeSceneToolRequest {
        let responseID = "response-\(callID)"
        try await socket.feed(["type": "response.created", "response": ["id": responseID, "metadata": creation.metadata]])
        let arguments = try String(data: JSONSerialization.data(withJSONObject: ["request": "Explain the selected component"]), encoding: .utf8)
        try await socket.feed(["type": "response.done", "response": [
            "id": responseID, "metadata": creation.metadata, "status": "completed",
            "output": [["type": "function_call", "name": "ask_astra", "call_id": callID, "arguments": arguments ?? ""]]
        ]])
        return try await executor.nextRequest()
    }

    func close() { session.disconnect(); executor.close(); audio.close() }

    static func pcm(frames: Int, amplitude: Int16) -> Data {
        var data = Data(capacity: frames * 2)
        let sample = UInt16(bitPattern: amplitude)
        for _ in 0..<frames {
            data.append(UInt8(truncatingIfNeeded: sample))
            data.append(UInt8(truncatingIfNeeded: sample >> 8))
        }
        return data
    }
}
