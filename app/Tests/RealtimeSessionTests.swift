import Foundation
import Testing

@MainActor
@Suite("Production Realtime conversation")
struct RealtimeSessionTests {
    @Test
    func typedAndSpokenTurnsUseOneConnectionAndWaitForTheirToolResult() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()

        #expect(f.session.sendText("Explain this", nodeIDs: ["component-a"], requestID: "typed-one"))
        let typed = try await f.socket.nextSent { $0.type == "response.create" && $0.phase == "tool" }
        let typedRequest = try await f.completeTool(typed, callID: "typed-call")
        #expect(typedRequest.source == .typed)
        #expect(typedRequest.nodeIDs == ["component-a"])
        #expect(f.executor.requests.count == 1)
        #expect(!f.socket.sent.contains { $0.phase == "final" })

        f.executor.resolve(typedRequest, installed: true)
        let typedOutput = try await f.socket.nextSent { $0.callID == "typed-call" }
        #expect(try typedOutput.decodedToolResult().outcome == .confirmedInstalled)
        let typedFinal = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == "typed-one" }
        #expect(typedFinal.response["output_modalities"] as? [String] == ["text"])
        #expect(typedFinal.response["tool_choice"] as? String == "none")
        #expect((typedFinal.response["instructions"] as? String)?.contains("typed-one") == true)
        try await finishFinal(f, creation: typedFinal, text: "The component is ready.")
        #expect(f.session.lastAssistantText == "The component is ready.")

        try await f.enableMicrophone()
        let voiceOffset = f.socket.sent.count
        try await f.beginSpeech(itemID: "spoken-item")
        let voice = try await f.commitSpeech(itemID: "spoken-item", after: voiceOffset)
        let voiceRequest = try await f.completeTool(voice, callID: "spoken-call")
        #expect(voiceRequest.source == .voice)
        #expect(voiceRequest.nodeIDs == ["component-a"])
        #expect(f.executor.requests.count == 2)
        #expect(!f.socket.sent.contains { $0.phase == "final" && $0.requestID == voiceRequest.requestID })

        f.executor.resolve(voiceRequest)
        _ = try await f.socket.nextSent { $0.callID == "spoken-call" }
        let spokenFinal = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == voiceRequest.requestID }
        #expect(spokenFinal.response["output_modalities"] as? [String] == ["audio"])
        #expect(spokenFinal.response["tool_choice"] as? String == "none")
        try await f.socket.feed(["type": "response.created", "response": ["id": "spoken-final", "metadata": spokenFinal.metadata]])
        try await f.socket.feed(["type": "response.output_audio_transcript.delta", "response_id": "spoken-final", "delta": "Here is the explanation."])
        try await f.socket.feed(audioDelta(responseID: "spoken-final", itemID: "spoken-output"))
        try await f.socket.feed(["type": "response.output_audio.done", "response_id": "spoken-final", "item_id": "spoken-output"])
        try await f.socket.feed(["type": "response.done", "response": ["id": "spoken-final", "metadata": spokenFinal.metadata, "status": "completed", "output": []]])
        #expect(f.audio.playback.count == 1)
        #expect(f.audio.completedItemIDs == ["spoken-output"])
        f.audio.eventSink?(.playbackFinished("spoken-output"))
        #expect(f.session.activity == .listening)
        #expect(f.session.lastAssistantText == "Here is the explanation.")
        #expect(f.socketCount == 1)
        #expect(f.credentialCount == 1)
        #expect(f.socket.sent.filter { $0.type == "session.update" }.count == 1)
    }

    @Test
    func oldVoiceCommitCannotReplaceNewTypedExecution() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "old-speech")
        #expect(f.bindings.count == 1)

        let offset = f.socket.sent.count
        #expect(f.session.sendText("Move this", nodeIDs: ["component-a"], requestID: "new-text"))
        let typed = try await f.socket.nextSent(after: offset) { $0.phase == "tool" }
        let request = try await f.completeTool(typed, callID: "new-text-call")
        try await f.socket.feed(["type": "input_audio_buffer.committed", "item_id": "old-speech"])
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "old-speech", "audio_start_ms": 0])
        try await f.socket.barrier()
        #expect(f.socket.sent.filter { $0.type == "response.create" && $0.phase == "tool" }.count == 1)
        #expect(f.executor.requests.map(\.requestID) == ["new-text"])

        f.executor.resolve(request, installed: true)
        let output = try await f.socket.nextSent { $0.callID == "new-text-call" }
        #expect(try output.decodedToolResult().outcome == .confirmedInstalled)
        _ = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == "new-text" }
    }

    @Test
    func shortLocalPauseInsideOneProviderUtteranceKeepsFirstSelection() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        f.selectedNodeIDs = ["first-component"]
        try await f.sendPCM(frames: 1_024)
        try await f.sendPCM(frames: 1_024)

        // Local onset detection ends at 200 ms of quiet, while provider VAD
        // waits 450 ms. Both speech bursts still belong to one provider item.
        try await f.sendPCM(frames: 6_000, amplitude: 0)
        f.selectedNodeIDs = ["later-component"]
        try await f.sendPCM(frames: 1_024)
        try await f.sendPCM(frames: 1_024)
        try await f.socket.feed([
            "type": "input_audio_buffer.speech_started",
            "item_id": "one-provider-utterance", "audio_start_ms": 0
        ])
        let creation = try await f.commitSpeech(itemID: "one-provider-utterance")
        let request = try await f.completeTool(creation, callID: "one-utterance-call")
        #expect(request.nodeIDs == ["first-component"])
        #expect(f.executor.requests.count == 1)
        f.executor.resolve(request)
        _ = try await f.socket.nextSent { $0.callID == "one-utterance-call" }
    }

    @Test
    func delayedFirstCommitPreservesTheNextUtterancesSelectionHint() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        f.selectedNodeIDs = ["first-component"]
        try await f.sendPCM(frames: 9_600)
        try await f.sendPCM(frames: 12_000, amplitude: 0)
        f.selectedNodeIDs = ["second-component"]
        try await f.sendPCM(frames: 9_600)
        try await f.sendPCM(frames: 10_800, amplitude: 0)

        // The first cloud callback is delayed until both local onsets exist.
        // Its end at 850 ms must preserve the second onset at 940 ms.
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "first-delayed", "audio_start_ms": 0])
        try await f.socket.feed(["type": "input_audio_buffer.speech_stopped", "item_id": "first-delayed", "audio_end_ms": 850])
        let firstCreation = try await f.commitSpeech(itemID: "first-delayed")
        let first = try await f.completeTool(firstCreation, callID: "first-delayed-call")
        #expect(first.nodeIDs == ["first-component"])
        f.executor.resolve(first)
        let firstFinal = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == first.requestID }
        try await finishFinal(f, creation: firstFinal, text: "First explanation.")

        let secondOffset = f.socket.sent.count
        // The provider includes 300 ms of prefix padding before the second
        // utterance's actual onset at 900 ms.
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "second-delayed", "audio_start_ms": 600])
        try await f.socket.feed(["type": "input_audio_buffer.speech_stopped", "item_id": "second-delayed", "audio_end_ms": 1_750])
        let secondCreation = try await f.commitSpeech(itemID: "second-delayed", after: secondOffset)
        let second = try await f.completeTool(secondCreation, callID: "second-delayed-call")
        #expect(second.nodeIDs == ["second-component"])
        #expect(f.executor.requests.map(\.nodeIDs) == [["first-component"], ["second-component"]])
        f.executor.resolve(second)
        _ = try await f.socket.nextSent { $0.callID == "second-delayed-call" }
    }

    @Test(arguments: [false, true])
    func localNoiseAfterCommittedVoiceNeedsProviderVADToInterrupt(providerConfirmsNewSpeech: Bool) async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "original-utterance")
        try await f.sendPCM(frames: 6_000, amplitude: 0)
        let originalCreation = try await f.commitSpeech(itemID: "original-utterance")
        try await f.socket.feed([
            "type": "response.created",
            "response": ["id": "original-response", "metadata": originalCreation.metadata]
        ])

        // This is the phone failure order: after response.created, the local
        // amplitude gate detects sound that cloud VAD may never call speech.
        f.selectedNodeIDs = ["new-component"]
        try await f.sendPCM(frames: 1_024)
        try await f.sendPCM(frames: 1_024)
        if providerConfirmsNewSpeech {
            try await f.socket.feed([
                "type": "input_audio_buffer.speech_started",
                "item_id": "confirmed-new-utterance", "audio_start_ms": 335
            ])
        }
        try await f.socket.feed([
            "type": "response.done", "response": [
                "id": "original-response", "metadata": originalCreation.metadata, "status": "completed",
                "output": [["type": "function_call", "name": "ask_astra", "call_id": "original-call",
                            "arguments": "{\"request\":\"Explain the original component\"}"]]
            ]
        ])

        if providerConfirmsNewSpeech {
            #expect(f.executor.requests.isEmpty)
            let offset = f.socket.sent.count
            let newCreation = try await f.commitSpeech(itemID: "confirmed-new-utterance", after: offset)
            let request = try await f.completeTool(newCreation, callID: "confirmed-new-call")
            #expect(request.nodeIDs == ["new-component"])
            f.executor.resolve(request)
            _ = try await f.socket.nextSent { $0.callID == "confirmed-new-call" }
            #expect(!f.socket.sent.contains { $0.callID == "original-call" || ($0.phase == "final" && $0.requestID == originalCreation.requestID) })
        } else {
            let request = try await f.executor.nextRequest()
            #expect(request.requestID == originalCreation.requestID)
            #expect(request.nodeIDs == ["component-a"])
            f.executor.resolve(request)
            _ = try await f.socket.nextSent { $0.callID == "original-call" }
            _ = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == request.requestID }
        }
        #expect(f.executor.requests.count == 1)
    }

    enum HistoryPattern: Equatable, Sendable {
        case continuousEnergy, belowLocalThreshold, laterLocalOnset
    }

    @Test(arguments: [HistoryPattern.continuousEnergy, .belowLocalThreshold, .laterLocalOnset])
    func delayedProviderSpeechUsesHistoricalSelectionWithoutFreshLocalOnset(pattern: HistoryPattern) async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        let amplitude: Int16 = pattern == .belowLocalThreshold ? 256 : 8_000

        // Forward 2.2 seconds of PCM. Continuous energy has only the original
        // noise onset; quiet input has none; the third case adds a later onset.
        f.selectedNodeIDs = ["noise-selection-a"]
        try await f.sendPCM(frames: 9_600, amplitude: amplitude)
        try await f.sendPCM(frames: 9_600, amplitude: amplitude)
        try await f.sendPCM(frames: 4_800, amplitude: amplitude)
        f.selectedNodeIDs = ["speech-selection-b"]
        try await f.sendPCM(frames: 12_000, amplitude: amplitude)
        f.selectedNodeIDs = ["arrival-selection-c"]
        if pattern == .laterLocalOnset {
            try await f.sendPCM(frames: 6_000, amplitude: 0)
            try await f.sendPCM(frames: 10_800, amplitude: amplitude)
        } else {
            try await f.sendPCM(frames: 12_000, amplitude: amplitude)
            try await f.sendPCM(frames: 4_800, amplitude: amplitude)
        }
        let expectedOnsets = switch pattern {
        case .continuousEnergy: 1
        case .belowLocalThreshold: 0
        case .laterLocalOnset: 2
        }
        #expect(f.bindings.count == expectedOnsets)

        // The delayed provider start includes 300 ms of padding. Its speech
        // position is 1,200 ms, inside B's [1,000, 1,500) ms history interval.
        // A is an old noise hint and C is the current selection at arrival.
        try await f.socket.feed([
            "type": "input_audio_buffer.speech_started",
            "item_id": "history-bound-utterance", "audio_start_ms": 900
        ])
        try await f.socket.feed([
            "type": "input_audio_buffer.speech_stopped",
            "item_id": "history-bound-utterance", "audio_end_ms": pattern == .laterLocalOnset ? 1_650 : 2_200
        ])
        let creation = try await f.commitSpeech(itemID: "history-bound-utterance")
        let request = try await f.completeTool(creation, callID: "history-bound-call")
        #expect(request.nodeIDs == ["speech-selection-b"])
        #expect(request.source == .voice)
        #expect(f.executor.requests.count == 1)
        f.executor.resolve(request)
        _ = try await f.socket.nextSent { $0.callID == "history-bound-call" }
        let final = try await f.socket.nextSent { $0.phase == "final" && $0.requestID == request.requestID }
        if pattern == .laterLocalOnset {
            try await finishFinal(f, creation: final, text: "Historical B explanation.")
            let offset = f.socket.sent.count
            // The later local onset at 1,790 ms lies beyond the earlier
            // provider window. It must survive and bind its own provider item.
            try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "later-c-utterance", "audio_start_ms": 1_450])
            try await f.socket.feed(["type": "input_audio_buffer.speech_stopped", "item_id": "later-c-utterance", "audio_end_ms": 2_200])
            let laterCreation = try await f.commitSpeech(itemID: "later-c-utterance", after: offset)
            let later = try await f.completeTool(laterCreation, callID: "later-c-call")
            #expect(later.nodeIDs == ["arrival-selection-c"])
            #expect(f.executor.requests.map(\.nodeIDs) == [["speech-selection-b"], ["arrival-selection-c"]])
            f.executor.resolve(later)
            _ = try await f.socket.nextSent { $0.callID == "later-c-call" }
        }
        #expect(f.socketCount == 1)
    }

    @Test(arguments: [false, true])
    func staleSpeechAfterClearCannotConsumeTheNewLocalBinding(explicitStop: Bool) async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "before-clear")
        let firstBinding = try #require(f.bindings.last)

        // Two 1,024-frame buffers have crossed the writer (85.34 ms). A clear
        // retires that input; provider timestamps retain the session timeline.
        let clearOffset = f.socket.sent.count
        if explicitStop { f.session.interrupt() }
        else { #expect(f.session.sendText("A new typed turn", nodeIDs: [], requestID: "clear-boundary")) }
        _ = try await f.socket.nextSent(after: clearOffset) { $0.type == "input_audio_buffer.clear" }
        try await f.socket.barrier()
        f.selectedNodeIDs = ["component-b"]
        try await f.sendPCM(frames: 9_600, amplitude: 0)
        try await f.sendPCM(frames: 1_024)
        try await f.sendPCM(frames: 1_024)
        let newBinding = try #require(f.bindings.last)
        #expect(newBinding.requestID != firstBinding.requestID)

        try await f.socket.feed(["type": "input_audio_buffer.committed", "item_id": "before-clear"])
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "late-old-item", "audio_start_ms": 0])
        try await f.socket.feed(["type": "input_audio_buffer.committed", "item_id": "late-old-item"])
        let turnOffset = f.socket.sent.count
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "new-item", "audio_start_ms": 500])
        let creation = try await f.commitSpeech(itemID: "new-item", after: turnOffset)
        let request = try await f.completeTool(creation, callID: "new-voice-call")
        #expect(request.requestID == newBinding.requestID)
        #expect(request.nodeIDs == ["component-b"])
        #expect(f.executor.requests.count == 1)
        f.executor.resolve(request)
        _ = try await f.socket.nextSent { $0.callID == "new-voice-call" }
    }

    @Test
    func microphoneFailureRetiresVoiceAndRejectsLateAudio() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "voice-before-failure")
        let creation = try await f.commitSpeech(itemID: "voice-before-failure")
        let request = try await f.completeTool(creation, callID: "failure-call")
        f.executor.resolve(request)
        let final = try await f.socket.nextSent { $0.phase == "final" }
        try await f.socket.feed(["type": "response.created", "response": ["id": "voice-final", "metadata": final.metadata]])

        let previousStops = f.audio.stopCount
        f.audio.failCapture()
        try await f.audio.waitForStop(after: previousStops)
        #expect(!f.session.isMicrophoneEnabled)
        #expect(f.session.lastError != nil)
        let priorPlayback = f.audio.playback.count
        try await f.socket.feed(audioDelta(responseID: "voice-final", itemID: "late-output"))
        try await f.socket.feed(["type": "response.done", "response": ["id": "voice-final", "metadata": final.metadata, "status": "completed", "output": []]])
        #expect(f.audio.playback.count == priorPlayback)
        #expect(f.session.activity != .delivering)
        #expect(f.session.isConnected)

        try await f.enableMicrophone()
        #expect(f.session.lastError == nil)
        #expect(f.session.isMicrophoneEnabled)
        #expect(f.socketCount == 1)
    }

    @Test
    func lateInputTranscriptSurvivesToolCompletionButNotInputReset() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "transcribed-item")
        let creation = try await f.commitSpeech(itemID: "transcribed-item")
        let request = try await f.completeTool(creation, callID: "transcribed-call")
        f.executor.resolve(request)
        _ = try await f.socket.nextSent { $0.callID == "transcribed-call" }

        // Tool completion releases the selection lock before asynchronous input
        // transcription necessarily finishes. Its owned item remains valid.
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.delta", "item_id": "transcribed-item", "delta": "Late "])
        #expect(f.session.liveTranscript == "Late ")
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "transcribed-item", "transcript": "Late transcript"])
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "other-item", "transcript": "Wrong item"])
        #expect(f.session.liveTranscript == "Late transcript")

        let clearOffset = f.socket.sent.count
        f.session.interrupt()
        _ = try await f.socket.nextSent(after: clearOffset) { $0.type == "input_audio_buffer.clear" }
        try await f.socket.barrier()
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.delta", "item_id": "transcribed-item", "delta": "Old delta"])
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "transcribed-item", "transcript": "Old completion"])
        #expect(f.session.liveTranscript.isEmpty)

        try await f.beginSpeech(itemID: "new-transcribed-item", audioStartMilliseconds: 100)
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.delta", "item_id": "new-transcribed-item", "delta": "New transcript"])
        try await f.socket.feed(["type": "conversation.item.input_audio_transcription.completed", "item_id": "transcribed-item", "transcript": "Obsolete completion"])
        #expect(f.session.liveTranscript == "New transcript")
        #expect(f.executor.requests.count == 1)
    }

    @Test
    func microphonePauseResetsOnsetAndOldRemoteEventsDoNotInterruptText() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "paused-item")
        let oldCaptureID = try #require(f.audio.currentCaptureID)
        let disabled = await f.session.setMicrophoneEnabled(false)
        #expect(disabled)
        let offset = f.socket.sent.count
        #expect(f.session.sendText("Explain this", nodeIDs: [], requestID: "text-while-paused"))
        let typed = try await f.socket.nextSent(after: offset) { $0.phase == "tool" }
        try await f.socket.feed(["type": "input_audio_buffer.speech_started", "item_id": "paused-item", "audio_start_ms": 0])
        try await f.socket.feed(["type": "input_audio_buffer.committed", "item_id": "paused-item"])
        let request = try await f.completeTool(typed, callID: "paused-text-call")
        #expect(request.requestID == "text-while-paused")
        f.executor.resolve(request)
        let final = try await f.socket.nextSent { $0.phase == "final" }
        try await finishFinal(f, creation: final, text: "Still connected.")

        try await f.enableMicrophone()
        let bindingCount = f.bindings.count
        let sentCount = f.socket.sent.count
        try f.audio.emitPCM(RealtimeFixture.pcm(frames: 1_024, amplitude: 8_000), captureID: oldCaptureID)
        try await f.sendPCM(frames: 1_024)
        try await f.sendPCM(frames: 1_024)
        #expect(f.bindings.count == bindingCount + 1)
        #expect(f.socket.sent.dropFirst(sentCount).filter { $0.type == "input_audio_buffer.append" }.count == 2)
        #expect(f.socketCount == 1)
    }

    @Test(arguments: [false, true])
    func interruptedToolStillRecordsActualTerminalResultWithoutOldNarration(installed: Bool) async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        #expect(f.session.sendText("Move this", nodeIDs: [], requestID: "interrupted"))
        let creation = try await f.socket.nextSent { $0.phase == "tool" }
        let request = try await f.completeTool(creation, callID: "interrupted-call")
        f.session.interrupt()
        f.executor.resolve(request, status: installed ? "completed" : "cancelled", installed: installed)
        let output = try await f.socket.nextSent { $0.callID == "interrupted-call" }
        let result = try output.decodedToolResult()
        #expect(result.outcome == (installed ? .confirmedInstalled : .cancelled))
        try await f.socket.barrier()
        #expect(f.socket.sent.filter { $0.callID == "interrupted-call" }.count == 1)
        #expect(!f.socket.sent.contains { $0.phase == "final" && $0.requestID == "interrupted" })
        #expect(f.session.isConnected)
    }

    @Test
    func duplicateCompletedToolResponseDoesNotExecuteTwice() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        #expect(f.session.sendText("Explain this", nodeIDs: [], requestID: "once"))
        let creation = try await f.socket.nextSent { $0.phase == "tool" }
        let request = try await f.completeTool(creation, callID: "once-call")
        let arguments = "{\"request\":\"Explain the selected component\"}"
        try await f.socket.feed(["type": "response.done", "response": [
            "id": "response-once-call", "metadata": creation.metadata, "status": "completed",
            "output": [["type": "function_call", "name": "ask_astra", "call_id": "once-call", "arguments": arguments]]
        ]])
        #expect(f.executor.requests.count == 1)
        f.executor.resolve(request)
        _ = try await f.socket.nextSent { $0.callID == "once-call" }
        #expect(f.socket.sent.filter { $0.callID == "once-call" }.count == 1)
    }

    @Test
    func playbackCutAfterProviderCompletionDoesNotLeaveDeliveringTurn() async throws {
        let f = RealtimeFixture()
        defer { f.close() }
        try await f.connect()
        try await f.enableMicrophone()
        try await f.beginSpeech(itemID: "cut-voice")
        let creation = try await f.commitSpeech(itemID: "cut-voice")
        let request = try await f.completeTool(creation, callID: "cut-call")
        f.executor.resolve(request)
        let final = try await f.socket.nextSent { $0.phase == "final" }
        try await f.socket.feed(["type": "response.created", "response": ["id": "cut-final", "metadata": final.metadata]])
        try await f.socket.feed(audioDelta(responseID: "cut-final", itemID: "cut-output"))
        try await f.socket.feed(["type": "response.done", "response": ["id": "cut-final", "metadata": final.metadata, "status": "completed", "output": []]])
        #expect(f.session.activity == .delivering)
        let cut = PlaybackCut(itemID: "cut-output", contentIndex: 0, playedMilliseconds: 20)
        f.audio.eventSink?(.routeChanged(cut, TestRealtimeAudio.route))
        try await f.socket.barrier()
        #expect(f.session.activity != .delivering)
        #expect(f.session.isConnected)
    }

    private func finishFinal(_ f: RealtimeFixture, creation: TestWireEvent, text: String) async throws {
        let id = "final-\(creation.requestID)"
        try await f.socket.feed(["type": "response.created", "response": ["id": id, "metadata": creation.metadata]])
        let deltaType = creation.response["output_modalities"] as? [String] == ["audio"]
            ? "response.output_audio_transcript.delta" : "response.output_text.delta"
        try await f.socket.feed(["type": deltaType, "response_id": id, "delta": text])
        try await f.socket.feed(["type": "response.done", "response": ["id": id, "metadata": creation.metadata, "status": "completed", "output": []]])
    }

    private func audioDelta(responseID: String, itemID: String) -> [String: Any] {
        ["type": "response.output_audio.delta", "response_id": responseID, "item_id": itemID,
         "content_index": 0, "delta": RealtimeFixture.pcm(frames: 480, amplitude: 1_000).base64EncodedString()]
    }
}
