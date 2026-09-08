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
    case failure(String)
}

/// `AVAudioEngine` invokes one input tap serially. The encoder never leaves that
/// callback and the emitted `Data` value is copied before crossing to MainActor.
private final class MicrophonePCMEncoder: @unchecked Sendable {
    private let converter: AVAudioConverter
    private let outputFormat: AVAudioFormat
    private let aggregate = Mutex(PCMAggregate())

    private struct PCMAggregate: Sendable {
        var buffers = 0
        var frames = 0
        var bytes = 0
        var lastLoggedAt = Date()
    }

    init?(inputFormat: AVAudioFormat) {
        guard inputFormat.sampleRate > 0,
              inputFormat.channelCount > 0,
              let outputFormat = AVAudioFormat(
                  commonFormat: .pcmFormatInt16,
                  sampleRate: Double(PCMCodec.sampleRate),
                  channels: 1,
                  interleaved: false
              ),
              let converter = AVAudioConverter(from: inputFormat, to: outputFormat)
        else { return nil }
        self.converter = converter
        self.outputFormat = outputFormat
    }

    func convert(_ input: AVAudioPCMBuffer) throws -> Data {
        let ratio = outputFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount(ceil(Double(input.frameLength) * ratio)) + 32
        guard let output = AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: capacity) else {
            throw VoiceSessionError.microphoneUnavailable
        }

        let suppliedInput = Mutex(false)
        var conversionError: NSError?
        let status = converter.convert(to: output, error: &conversionError) { _, inputStatus in
            let shouldSupply = suppliedInput.withLock { supplied in
                if supplied { return false }
                supplied = true
                return true
            }
            if !shouldSupply {
                inputStatus.pointee = .noDataNow
                return nil
            }
            inputStatus.pointee = .haveData
            return input
        }

        if let conversionError { throw conversionError }
        guard status != .error,
              output.frameLength > 0,
              let samples = output.int16ChannelData?.pointee
        else { return Data() }
        let byteCount = Int(output.frameLength) * PCMCodec.bytesPerFrame
        let data = Data(bytes: samples, count: byteCount)
        let summary = aggregate.withLock { aggregate -> (Int, Int, Int)? in
            aggregate.buffers += 1
            aggregate.frames += Int(output.frameLength)
            aggregate.bytes += byteCount
            guard Date().timeIntervalSince(aggregate.lastLoggedAt) >= 1 else { return nil }
            let summary = (aggregate.buffers, aggregate.frames, aggregate.bytes)
            aggregate.buffers = 0
            aggregate.frames = 0
            aggregate.bytes = 0
            aggregate.lastLoggedAt = Date()
            return summary
        }
        if let summary {
            DiagnosticsLog.shared.record("microphone_pcm_summary", component: "voice.audio", fields: [
                "buffer_count": String(summary.0),
                "frame_count": String(summary.1),
                "byte_count": String(summary.2),
            ])
        }
        return data
    }
}

@MainActor
final class AudioIOController {
    private let logger = Logger(subsystem: "com.astra.spatialdemo", category: "voice-audio")
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let onMicrophonePCM: @Sendable (Data) -> Void
    private let onMicrophoneFailure: @Sendable (String) -> Void
    private let onEvent: @MainActor (AudioIOEvent) -> Void

    private var notificationTokens: [NSObjectProtocol] = []
    private var encoder: MicrophonePCMEncoder?
    private var isTapInstalled = false
    private var wantsAudio = false
    private var playbackItemID: String?
    private var playbackContentIndex = 0
    private var playbackAccounting = PlaybackAccounting()
    private var playbackGeneration = 0
    private var pendingPlaybackBuffers = 0
    private var completedOutputItemID: String?
    private var isReconfiguring = false
    private var voiceProcessingEnabled = false

    init(
        onMicrophonePCM: @escaping @Sendable (Data) -> Void,
        onMicrophoneFailure: @escaping @Sendable (String) -> Void,
        onEvent: @escaping @MainActor (AudioIOEvent) -> Void
    ) {
        self.onMicrophonePCM = onMicrophonePCM
        self.onMicrophoneFailure = onMicrophoneFailure
        self.onEvent = onEvent
        observeAudioSession()
    }

    deinit {
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
        }
    }

    static func requestMicrophonePermission() async -> Bool {
        await withCheckedContinuation { continuation in
            AVAudioApplication.requestRecordPermission { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    func start() throws -> AudioRouteReport {
        diagnostic("audio_start_requested")
        wantsAudio = true
        do {
            try configureAudioSession()
            let report = try rebuildAudioGraph()
            diagnostic("audio_started", fields: report.diagnosticFields)
            return report
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
        engine.stop()
        engine.reset()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    func enqueuePlayback(_ data: Data, itemID: String, contentIndex: Int) throws {
        let frameCount = try PCMCodec.frameCount(inPCM16: data)
        guard frameCount > 0, let playbackFormat else { return }

        if playbackItemID != itemID {
            _ = interruptPlayback()
            playbackItemID = itemID
            playbackContentIndex = contentIndex
            completedOutputItemID = nil
            playbackGeneration += 1
            if !player.isPlaying { player.play() }
            playbackAccounting.begin(at: currentPlayerSampleTime ?? 0)
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
        player.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.playbackBufferFinished(itemID: itemID, generation: generation)
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
        let playedMilliseconds = playbackAccounting.playedMilliseconds(at: currentPlayerSampleTime ?? 0)
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

    private var currentPlayerSampleTime: Int64? {
        guard let renderTime = player.lastRenderTime,
              let playerTime = player.playerTime(forNodeTime: renderTime)
        else { return nil }
        return playerTime.sampleTime
    }

    private func installInputTap(input: AVAudioInputNode) throws {
        removeInputTap()
        let inputFormat = input.inputFormat(forBus: 0)
        guard let encoder = MicrophonePCMEncoder(inputFormat: inputFormat) else {
            throw VoiceSessionError.microphoneUnavailable
        }
        self.encoder = encoder
        let sink = onMicrophonePCM
        let failureSink = onMicrophoneFailure
        input.installTap(onBus: 0, bufferSize: 1_024, format: inputFormat) { buffer, _ in
            do {
                let pcm = try encoder.convert(buffer)
                if !pcm.isEmpty { sink(pcm) }
            } catch {
                failureSink(error.localizedDescription)
            }
        }
        isTapInstalled = true
    }

    private func removeInputTap() {
        if isTapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            isTapInstalled = false
        }
        encoder = nil
    }

    private func playbackBufferFinished(itemID: String, generation: Int) {
        guard generation == playbackGeneration, playbackItemID == itemID else {
            diagnostic("playback_callback_ignored", level: .debug, fields: [
                "item_id": itemID,
                "reason": "stale_generation_or_item",
            ])
            return
        }
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
        notificationTokens.append(center.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: engine,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.handleEngineConfigurationChange()
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
            diagnostic("audio_interruption_began")
            let cut = interruptPlayback()
            removeInputTap()
            engine.stop()
            onEvent(.interruptionBegan(cut))
        case .ended:
            let options = AVAudioSession.InterruptionOptions(rawValue: rawOptions)
            guard wantsAudio, options.contains(.shouldResume) else {
                diagnostic("audio_interruption_end_ignored", level: .warning, fields: [
                    "wants_audio": String(wantsAudio),
                    "should_resume": String(options.contains(.shouldResume)),
                ])
                return
            }
            do {
                try AVAudioSession.sharedInstance().setActive(true)
                _ = try rebuildAudioGraph()
                diagnostic("audio_interruption_recovered")
                onEvent(.interruptionEnded)
            } catch {
                onEvent(.failure(error.localizedDescription))
            }
        @unknown default:
            break
        }
    }

    private func handleRouteChange(rawReason: UInt?) {
        guard wantsAudio else {
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
            onEvent(.failure(error.localizedDescription))
        }
    }

    private func handleEngineConfigurationChange() {
        guard wantsAudio, !isReconfiguring else {
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
            onEvent(.failure(error.localizedDescription))
        }
    }

    private func restartAfterMediaServicesReset() {
        guard wantsAudio else {
            diagnostic("media_services_reset_ignored", level: .debug, fields: ["reason": "audio_not_wanted"])
            return
        }
        diagnostic("media_services_reset")
        let cut = interruptPlayback()
        do {
            try configureAudioSession()
            let report = try rebuildAudioGraph()
            diagnostic("media_services_reset_recovered", fields: report.diagnosticFields)
            onEvent(.routeChanged(cut, report))
        } catch {
            onEvent(.failure(error.localizedDescription))
        }
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
        guard !isReconfiguring else { throw VoiceSessionError.microphoneUnavailable }
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
        let inputFormat = input.inputFormat(forBus: 0)
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
