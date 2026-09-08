@preconcurrency import AVFAudio
import Foundation
import SpatialApple
import os
import Synchronization

enum AudioIOEvent: Sendable {
    case interruptionBegan(PlaybackCut?)
    case interruptionEnded
    case routeChanged(PlaybackCut?, AudioRouteReport)
    case configurationChangeBegan(PlaybackCut?)
    case configurationChangeEnded(AudioRouteReport)
    case playbackFinished(String)
    case failure(String, PlaybackCut? = nil)
}

nonisolated enum MicrophoneCaptureError: Error, LocalizedError {
    case bufferOverflow
    case chunkTooLarge

    var errorDescription: String? {
        switch self {
        case .bufferOverflow: "Microphone processing fell behind. Tap the microphone to reconnect."
        case .chunkTooLarge: "The microphone returned an oversized audio buffer."
        }
    }
}

/// Each installed tap owns one gate. Removing the tap permanently closes it;
/// rotating its ID rejects frames already being converted or awaiting consumption.
nonisolated final class MicrophoneCaptureGate: Sendable {
    static let maximumChunkBytes = 32 * 1_024
    private struct State: Sendable {
        var captureID: UUID?
        let continuation: AsyncThrowingStream<MicrophoneChunk, Error>.Continuation
    }
    private let state: Mutex<State>

    init(captureID: UUID, continuation: AsyncThrowingStream<MicrophoneChunk, Error>.Continuation) {
        state = Mutex(State(captureID: captureID, continuation: continuation))
    }

    var currentCaptureID: UUID? { snapshot() }

    func snapshot() -> UUID? { state.withLock { $0.captureID } }

    @discardableResult
    func rotate() -> UUID? {
        state.withLock { state in
            guard state.captureID != nil else { return nil }
            let id = UUID()
            state.captureID = id
            return id
        }
    }

    func invalidate() { state.withLock { $0.captureID = nil } }

    func yield(_ data: Data, captureID: UUID) {
        enqueue(data, captureID: captureID)?.finish()
    }

    /// Finishing can synchronously call a termination handler, so callers finish
    /// only after releasing both the gate lock and the converter lock.
    fileprivate struct Termination: Sendable {
        let continuation: AsyncThrowingStream<MicrophoneChunk, Error>.Continuation
        let error: any Error
        func finish() { continuation.finish(throwing: error) }
    }

    fileprivate func enqueue(_ data: Data, captureID: UUID) -> Termination? {
        state.withLock { state in
            guard state.captureID == captureID, !data.isEmpty else { return nil }
            guard data.count <= Self.maximumChunkBytes else {
                state.captureID = nil
                return Termination(continuation: state.continuation, error: MicrophoneCaptureError.chunkTooLarge)
            }
            switch state.continuation.yield(MicrophoneChunk(captureID: captureID, data: data)) {
            case .enqueued: return nil
            case .dropped:
                state.captureID = nil
                return Termination(continuation: state.continuation, error: MicrophoneCaptureError.bufferOverflow)
            case .terminated:
                state.captureID = nil
                return nil
            @unknown default:
                state.captureID = nil
                return Termination(continuation: state.continuation, error: MicrophoneCaptureError.bufferOverflow)
            }
        }
    }

    func finish(throwing error: any Error, captureID: UUID) {
        let continuation = state.withLock { state -> AsyncThrowingStream<MicrophoneChunk, Error>.Continuation? in
            guard state.captureID == captureID else { return nil }
            state.captureID = nil
            return state.continuation
        }
        continuation?.finish(throwing: error)
    }
}

/// Audio callbacks only update these counters. Formatting and log I/O happen
/// on MainActor once per second, including intervals with no tap callbacks.
nonisolated private final class MicrophoneCaptureDiagnostics: Sendable {
    struct Snapshot: Sendable {
        var tapBuffers = 0
        var tapFrames = 0
        var convertedBuffers = 0
        var convertedFrames = 0
        var emptyConversions = 0
        var failedConversions = 0
        var staleConversions = 0
        var inputSampleRate = 0.0
        var inputChannels = 0
    }
    private let counters = Mutex(Snapshot())

    func recordInput(_ input: AVAudioPCMBuffer) {
        counters.withLock { counters in
            counters.tapBuffers += 1
            counters.tapFrames += Int(input.frameLength)
            counters.inputSampleRate = input.format.sampleRate
            counters.inputChannels = Int(input.format.channelCount)
        }
    }

    func recordOutput(frameCount: Int) {
        counters.withLock { counters in
            if frameCount == 0 { counters.emptyConversions += 1 }
            else {
                counters.convertedBuffers += 1
                counters.convertedFrames += frameCount
            }
        }
    }

    func recordFailure() { counters.withLock { $0.failedConversions += 1 } }
    func recordStale() { counters.withLock { $0.staleConversions += 1 } }

    func takeSnapshot() -> Snapshot {
        counters.withLock { counters in
            let result = counters
            counters = Snapshot()
            return result
        }
    }
}

/// Converter state and delivery share one lock, preserving conversion order even
/// if the SDK calls a tap concurrently. PCM bytes are copied before delivery.
nonisolated private final class MicrophonePCMEncoder: Sendable {
    private struct ConverterState {
        let converter: AVAudioConverter
        let outputFormat: AVAudioFormat
        var captureID: UUID?
    }
    private let state: Mutex<ConverterState>
    private let diagnostics: MicrophoneCaptureDiagnostics

    init?(inputFormat: AVAudioFormat, diagnostics: MicrophoneCaptureDiagnostics) {
        guard inputFormat.sampleRate.isFinite, inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(PCMCodec.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        state = Mutex(ConverterState(converter: converter, outputFormat: outputFormat))
        self.diagnostics = diagnostics
    }

    func convert(_ input: AVAudioPCMBuffer, gate: MicrophoneCaptureGate, captureID: UUID) throws {
        diagnostics.recordInput(input)
        do {
            let termination = try state.withLock { state -> MicrophoneCaptureGate.Termination? in
                guard gate.currentCaptureID == captureID else {
                    diagnostics.recordStale()
                    return nil
                }
                if state.captureID != captureID {
                    state.converter.reset()
                    state.captureID = captureID
                }
                let ratio = state.outputFormat.sampleRate / input.format.sampleRate
                let requiredFrames = ceil(Double(input.frameLength) * ratio) + 32
                guard requiredFrames.isFinite, requiredFrames > 0,
                      requiredFrames <= Double(MicrophoneCaptureGate.maximumChunkBytes / PCMCodec.bytesPerFrame)
                else { throw MicrophoneCaptureError.chunkTooLarge }
                guard let output = AVAudioPCMBuffer(
                    pcmFormat: state.outputFormat,
                    frameCapacity: AVAudioFrameCount(requiredFrames)
                ) else { throw VoiceSessionError.microphoneUnavailable }

                let suppliedInput = Mutex(false)
                var conversionError: NSError?
                let status = state.converter.convert(to: output, error: &conversionError) { _, inputStatus in
                    let shouldSupply = suppliedInput.withLock { supplied in
                        if supplied { return false }
                        supplied = true
                        return true
                    }
                    guard shouldSupply else {
                        inputStatus.pointee = .noDataNow
                        return nil
                    }
                    inputStatus.pointee = .haveData
                    return input
                }
                if let conversionError { throw conversionError }
                guard status != .error else { throw VoiceSessionError.microphoneUnavailable }
                diagnostics.recordOutput(frameCount: Int(output.frameLength))
                guard output.frameLength > 0, let samples = output.int16ChannelData?.pointee else { return nil }
                let data = Data(bytes: samples, count: Int(output.frameLength) * PCMCodec.bytesPerFrame)
                return gate.enqueue(data, captureID: captureID)
            }
            termination?.finish()
        } catch {
            diagnostics.recordFailure()
            throw error
        }
    }
}

@MainActor
final class AudioIOController {
    private let logger = Logger(subsystem: "com.astra.spatialdemo", category: "voice-audio")
    private var engine = AVAudioEngine()
    private var player = AVAudioPlayerNode()
    private let onEvent: @MainActor (AudioIOEvent) -> Void

    private var notificationTokens: [NSObjectProtocol] = []
    private var encoder: MicrophonePCMEncoder?
    private var captureDiagnostics: MicrophoneCaptureDiagnostics?
    private var diagnosticsTask: Task<Void, Never>?
    private var captureGate: MicrophoneCaptureGate?
    private var captureContinuation: AsyncThrowingStream<MicrophoneChunk, Error>.Continuation?
    private var isTapInstalled = false
    private var wantsAudio = false
    private var playbackItemID: String?
    private var playbackContentIndex = 0
    private var playbackAccounting = PlaybackAccounting()
    private var playbackGeneration = 0
    private var pendingPlaybackBuffers = 0
    private var completedOutputItemID: String?
    private var isReconfiguring = false
    private var isInterrupted = false
    private var voiceProcessingEnabled = false

    init(onEvent: @escaping @MainActor (AudioIOEvent) -> Void) {
        self.onEvent = onEvent
        observeAudioSession()
    }

    deinit {
        diagnosticsTask?.cancel()
        captureGate?.invalidate()
        captureContinuation?.finish()
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { @Sendable granted in
                continuation.resume(returning: granted)
            }
        }
    }

    var currentCaptureID: UUID? { captureGate?.currentCaptureID }

    @discardableResult
    func rotateCaptureID() -> UUID? { captureGate?.rotate() }

    func start() throws -> AudioCapture {
        guard !isInterrupted else { throw VoiceSessionError.microphoneUnavailable }
        if wantsAudio { stop() }
        diagnostic("audio_start_requested")
        let sessionID = UUID()
        let (stream, continuation) = AsyncThrowingStream<MicrophoneChunk, Error>.makeStream(
            bufferingPolicy: .bufferingOldest(8)
        )
        captureContinuation = continuation
        captureDiagnostics = MicrophoneCaptureDiagnostics()
        wantsAudio = true
        do {
            try configureAudioSession()
            let report = try rebuildAudioGraph()
            diagnostic("audio_started", fields: report.diagnosticFields)
            startCaptureDiagnostics()
            return AudioCapture(sessionID: sessionID, route: report, stream: stream)
        } catch {
            diagnostic("audio_start_failed", level: .error, fields: [
                "error_type": String(describing: type(of: error)),
            ])
            stop()
            throw error
        }
    }

    func stop() {
        diagnostic("audio_stop_requested")
        wantsAudio = false
        _ = interruptPlayback()
        removeInputTap()
        diagnosticsTask?.cancel()
        diagnosticsTask = nil
        recordCaptureDiagnostics()
        captureDiagnostics = nil
        captureContinuation?.finish()
        captureContinuation = nil
        engine.stop()
        engine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func enqueuePlayback(_ data: Data, itemID: String, contentIndex: Int) throws {
        guard wantsAudio, !isInterrupted, !isReconfiguring, engine.isRunning else {
            throw VoiceSessionError.realtime("Audio output is unavailable. Tap the microphone to reconnect.")
        }
        let frameCount = try PCMCodec.frameCount(inPCM16: data)
        guard frameCount > 0, let playbackFormat else { return }

        if playbackItemID != itemID {
            _ = interruptPlayback()
            playbackItemID = itemID
            playbackContentIndex = contentIndex
            completedOutputItemID = nil
            playbackGeneration += 1
            if !player.isPlaying { player.play() }
            playbackAccounting.begin()
            diagnostic("playback_started", fields: [
                "item_id": itemID,
                "content_index": String(contentIndex),
            ])
        }

        guard let buffer = AVAudioPCMBuffer(
            pcmFormat: playbackFormat,
            frameCapacity: AVAudioFrameCount(frameCount)
        ), let channel = buffer.int16ChannelData?.pointee
        else { throw VoiceSessionError.realtime("Could not allocate an audio playback buffer.") }

        buffer.frameLength = AVAudioFrameCount(frameCount)
        _ = data.copyBytes(to: UnsafeMutableBufferPointer(start: channel, count: frameCount))
        playbackAccounting.append(frameCount: frameCount)
        pendingPlaybackBuffers += 1
        let generation = playbackGeneration
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { @Sendable [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackBufferFinished(itemID: itemID, generation: generation, frameCount: frameCount)
            }
        }
        if !player.isPlaying { player.play() }
    }

    func markOutputComplete(itemID: String) {
        diagnostic("playback_output_complete", fields: ["item_id": itemID])
        completedOutputItemID = itemID
        finishPlaybackIfDrained(itemID: itemID)
    }

    @discardableResult
    func interruptPlayback() -> PlaybackCut? {
        guard let itemID = playbackItemID else { return nil }
        let playedMilliseconds = playbackAccounting.playedMilliseconds
        let cut = PlaybackCut(
            itemID: itemID,
            contentIndex: playbackContentIndex,
            playedMilliseconds: playedMilliseconds
        )
        playbackGeneration += 1
        player.stop()
        player.reset()
        playbackItemID = nil
        completedOutputItemID = nil
        pendingPlaybackBuffers = 0
        playbackAccounting = PlaybackAccounting()
        diagnostic("playback_interrupted", fields: [
            "item_id": itemID,
            "played_ms": String(playedMilliseconds),
        ])
        return cut
    }

    private var playbackFormat: AVAudioFormat? {
        AVAudioFormat(
            commonFormat: .pcmFormatInt16,
            sampleRate: Double(PCMCodec.sampleRate),
            channels: 1,
            interleaved: false
        )
    }

    private func installInputTap(input: AVAudioInputNode) throws {
        removeInputTap()
        let inputFormat = input.outputFormat(forBus: 0)
        guard let continuation = captureContinuation,
              let diagnostics = captureDiagnostics,
              let encoder = MicrophonePCMEncoder(inputFormat: inputFormat, diagnostics: diagnostics)
        else { throw VoiceSessionError.microphoneUnavailable }
        let gate = MicrophoneCaptureGate(captureID: UUID(), continuation: continuation)
        self.encoder = encoder
        captureGate = gate
        // This legacy SDK block does not express Sendable. Explicit isolation
        // prevents inheriting MainActor on AVAudioEngine's audio service queue.
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { @Sendable buffer, _ in
            guard let captureID = gate.snapshot() else { return }
            do {
                try encoder.convert(buffer, gate: gate, captureID: captureID)
            } catch {
                gate.finish(throwing: error, captureID: captureID)
            }
        }
        isTapInstalled = true
    }

    private func removeInputTap() {
        captureGate?.invalidate()
        captureGate = nil
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        encoder = nil
    }

    private func playbackBufferFinished(itemID: String, generation: Int, frameCount: Int) {
        guard generation == playbackGeneration, playbackItemID == itemID else {
            diagnostic("playback_callback_ignored", level: .debug, fields: [
                "item_id": itemID,
                "reason": "stale_generation_or_item",
            ])
            return
        }
        playbackAccounting.complete(frameCount: frameCount)
        pendingPlaybackBuffers = max(0, pendingPlaybackBuffers - 1)
        finishPlaybackIfDrained(itemID: itemID)
    }

    private func finishPlaybackIfDrained(itemID: String) {
        guard playbackItemID == itemID, completedOutputItemID == itemID,
              pendingPlaybackBuffers == 0
        else { return }
        playbackItemID = nil
        completedOutputItemID = nil
        playbackAccounting = PlaybackAccounting()
        diagnostic("playback_completed", fields: ["item_id": itemID])
        onEvent(.playbackFinished(itemID))
    }

    private func observeAudioSession() {
        let center = NotificationCenter.default
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawType = (notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber)?.uintValue
            let rawOptions = (notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
            Task { @MainActor [weak self] in
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let rawReason = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
            Task { @MainActor [weak self] in
                self?.handleRouteChange(rawReason: rawReason)
            }
        })
        notificationTokens.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.restartAfterMediaServicesReset()
            }
        })
        let observedEngineID = ObjectIdentifier(engine)
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, ObjectIdentifier(self.engine) == observedEngineID else { return }
                self.handleEngineConfigurationChange()
            }
        })
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else {
            diagnostic("audio_interruption_ignored", level: .warning, fields: ["reason": "invalid_type"])
            return
        }

        switch type {
        case .began:
            isInterrupted = true
            diagnostic("audio_interruption_began")
            let cut = interruptPlayback()
            removeInputTap()
            engine.stop()
            onEvent(.interruptionBegan(cut))
        case .ended:
            isInterrupted = false
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard wantsAudio else { return }
            guard options.contains(.shouldResume) else {
                diagnostic("audio_interruption_end_ignored", level: .warning, fields: [
                    "wants_audio": String(wantsAudio),
                    "should_resume": String(options.contains(.shouldResume)),
                ])
                failCapture("Audio was interrupted. Tap the microphone to reconnect.")
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                _ = try rebuildAudioGraph()
                diagnostic("audio_interruption_recovered")
                onEvent(.interruptionEnded)
            } catch {
                failCapture(error.localizedDescription)
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard wantsAudio, !isInterrupted, !isReconfiguring else {
            diagnostic("audio_route_callback_ignored", level: .debug, fields: ["reason": "audio_not_wanted"])
            return
        }
        if let rawReason, let reason = AVAudioSession.RouteChangeReason(rawValue: rawReason) {
            logger.info("Audio route changed, reason: \(reason.rawValue)")
        }
        diagnostic("audio_route_changed", fields: [
            "reason": rawReason.map { String($0) } ?? "unknown",
        ])
        let cut = interruptPlayback()
        do {
            let report = try rebuildAudioGraph()
            diagnostic("audio_route_recovered", fields: report.diagnosticFields)
            onEvent(.routeChanged(cut, report))
        } catch {
            failCapture(error.localizedDescription, cut: cut)
        }
    }

    private func handleEngineConfigurationChange() {
        guard wantsAudio, !isReconfiguring, !isInterrupted else {
            diagnostic("engine_configuration_callback_ignored", level: .debug, fields: [
                "wants_audio": String(wantsAudio),
                "already_reconfiguring": String(isReconfiguring),
            ])
            return
        }
        // Apple's configuration-change contract stops and uninitializes the
        // engine. Ignore notifications generated while an already-running
        // graph is deliberately being configured.
        guard !engine.isRunning else {
            diagnostic("engine_configuration_callback_ignored", level: .debug, fields: ["reason": "engine_running"])
            return
        }
        diagnostic("engine_configuration_change_began")
        let cut = interruptPlayback()
        onEvent(.configurationChangeBegan(cut))
        do {
            let report = try rebuildAudioGraph()
            diagnostic("engine_configuration_change_recovered", fields: report.diagnosticFields)
            onEvent(.configurationChangeEnded(report))
        } catch {
            failCapture(error.localizedDescription)
        }
    }

    private func restartAfterMediaServicesReset() {
        diagnostic("media_services_reset")
        let wasWanted = wantsAudio
        let cut = interruptPlayback()
        stop()
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens.removeAll()
        engine = AVAudioEngine()
        player = AVAudioPlayerNode()
        isInterrupted = false
        voiceProcessingEnabled = false
        observeAudioSession()
        if wasWanted {
            onEvent(.failure("Audio services restarted. Tap the microphone to reconnect.", cut))
        }
    }

    private func failCapture(_ message: String, cut: PlaybackCut? = nil) {
        let cut = cut ?? interruptPlayback()
        stop()
        onEvent(.failure(message, cut))
    }

    private func startCaptureDiagnostics() {
        diagnosticsTask?.cancel()
        diagnosticsTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(1)) }
                catch { return }
                guard !Task.isCancelled else { return }
                self?.recordCaptureDiagnostics()
            }
        }
    }

    private func recordCaptureDiagnostics() {
        guard let snapshot = captureDiagnostics?.takeSnapshot() else { return }
        let format = engine.inputNode.outputFormat(forBus: 0)
        diagnostic("microphone_capture_summary", fields: [
            "tap_buffer_count": String(snapshot.tapBuffers),
            "tap_frame_count": String(snapshot.tapFrames),
            "converted_buffer_count": String(snapshot.convertedBuffers),
            "converted_frame_count": String(snapshot.convertedFrames),
            "empty_conversion_count": String(snapshot.emptyConversions),
            "conversion_failure_count": String(snapshot.failedConversions),
            "stale_conversion_count": String(snapshot.staleConversions),
            "tap_sample_rate": String(snapshot.inputSampleRate),
            "tap_channel_count": String(snapshot.inputChannels),
            "output_format_sample_rate": String(format.sampleRate),
            "output_format_channel_count": String(format.channelCount),
            "engine_running": String(engine.isRunning),
            "capture_active": String(currentCaptureID != nil),
            "interrupted": String(isInterrupted),
            "voice_processing_enabled": String(voiceProcessingEnabled),
        ])
    }

    private func configureAudioSession() throws {
        diagnostic("audio_session_configuring")
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.defaultToSpeaker, .allowBluetoothHFP]
        )
        try session.setActive(true)
        diagnostic("audio_session_configured")
    }

    private func rebuildAudioGraph() throws -> AudioRouteReport {
        guard wantsAudio, !isReconfiguring, !isInterrupted, captureContinuation != nil
        else { throw VoiceSessionError.microphoneUnavailable }
        isReconfiguring = true
        defer { isReconfiguring = false }

        removeInputTap()
        engine.stop()
        if !engine.attachedNodes.contains(player) {
            engine.attach(player)
        } else {
            engine.disconnectNodeOutput(player)
        }

        do {
            try engine.inputNode.setVoiceProcessingEnabled(true)
            voiceProcessingEnabled = engine.inputNode.isVoiceProcessingEnabled
        } catch {
            voiceProcessingEnabled = false
            logger.notice("Voice processing could not be enabled (details withheld; see structured diagnostics)")
            diagnostic("voice_processing_unavailable", level: .warning, fields: [
                "error_type": String(describing: type(of: error)),
            ])
        }

        let input = engine.inputNode
        let inputFormat = input.outputFormat(forBus: 0)
        guard inputFormat.sampleRate > 0, inputFormat.channelCount > 0,
              let playbackFormat
        else { throw VoiceSessionError.microphoneUnavailable }
        engine.connect(player, to: engine.mainMixerNode, format: playbackFormat)
        try installInputTap(input: input)
        engine.prepare()
        try engine.start()
        let report = currentRouteReport(inputFormat: inputFormat)
        diagnostic("audio_graph_ready", fields: report.diagnosticFields)
        return report
    }

    private func currentRouteReport(inputFormat: AVAudioFormat) -> AudioRouteReport {
        let route = AVAudioSession.sharedInstance().currentRoute
        return AudioRouteReport(
            inputSampleRate: inputFormat.sampleRate,
            inputChannelCount: Int(inputFormat.channelCount),
            inputPortTypes: route.inputs.map { $0.portType.rawValue },
            outputPortTypes: route.outputs.map { $0.portType.rawValue },
            voiceProcessingEnabled: voiceProcessingEnabled
        )
    }

    private func diagnostic(
        _ name: String,
        level: DiagnosticLevel = .info,
        fields: [String: String] = [:]
    ) {
        DiagnosticsLog.shared.record(name, component: "voice.audio", level: level, fields: fields)
    }
}

private extension AudioRouteReport {
    var diagnosticFields: [String: String] {
        [
            "input_sample_rate": String(Int(inputSampleRate.rounded())),
            "input_channel_count": String(inputChannelCount),
            "input_ports": inputPortTypes.joined(separator: ","),
            "output_ports": outputPortTypes.joined(separator: ","),
            "voice_processing_enabled": String(voiceProcessingEnabled),
        ]
    }
}
