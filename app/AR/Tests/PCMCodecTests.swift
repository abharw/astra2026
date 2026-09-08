import Foundation
import Testing

@MainActor
@Suite struct PCMCodecTests {
    @Test(arguments: [0, 1, 128, 512, 1_024, 2_048])
    func completePCM16FramesAreCounted(frameCount: Int) throws {
        let data = Data(repeating: 0, count: frameCount * 2)

        #expect(try PCMCodec.frameCount(inPCM16: data) == frameCount)
    }

    @Test(arguments: [1, 3, 255, 4_097])
    func incompletePCM16SamplesAreRejected(byteCount: Int) {
        let data = Data(repeating: 0, count: byteCount)

        #expect(throws: VoiceSessionError.self) {
            try PCMCodec.frameCount(inPCM16: data)
        }
    }

    @Test(arguments: [128, 512, 1_024, 2_048])
    func equalAudioDurationsDetectSeparateUtterances(bufferFrames: Int) {
        var detector = VoiceOnsetDetector()

        // Each callback size receives the same 250 ms speech, 500 ms pause,
        // and 250 ms speech. A pause must end the first utterance even when
        // the audio engine delivers fewer, larger buffers.
        let first = feed(
            frameCount: 6_000, sample: 4_096, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(first == [.began])
        #expect(detector.isSpeaking)

        let pause = feed(
            frameCount: 12_000, sample: 0, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(pause == [.ended])
        #expect(!detector.isSpeaking)

        let second = feed(
            frameCount: 6_000, sample: 4_096, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(second == [.began])
        #expect(detector.isSpeaking)
    }

    @Test(arguments: [128, 512, 1_024, 2_048])
    func onsetAndEndUseAudioDurationAcrossCallbackSizes(bufferFrames: Int) {
        var detector = VoiceOnsetDetector(
            minimumVoicedDuration: 0.04, minimumQuietDuration: 0.2
        )
        let beforeOnset = feed(
            frameCount: 959, sample: 4_096, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(beforeOnset.isEmpty)
        #expect(!detector.isSpeaking)

        let onset = feed(frameCount: 1, sample: 4_096, bufferFrames: bufferFrames, to: &detector)
        #expect(onset == [.began])

        let beforeEnd = feed(
            frameCount: 4_799, sample: 0, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(beforeEnd.isEmpty)
        #expect(detector.isSpeaking)

        let end = feed(frameCount: 1, sample: 0, bufferFrames: bufferFrames, to: &detector)
        #expect(end == [.ended])
        #expect(!detector.isSpeaking)
    }

    @Test(arguments: [128, 512, 1_024, 2_048])
    func resetWhileSpeakingAllowsFreshSpeechWithoutSilence(bufferFrames: Int) {
        var detector = VoiceOnsetDetector()
        let beforeReset = feed(
            frameCount: 6_000, sample: 4_096, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(beforeReset == [.began])
        #expect(detector.isSpeaking)

        detector.reset()
        #expect(!detector.isSpeaking)

        // No quiet audio arrives between stopping and restarting capture.
        let afterReset = feed(
            frameCount: 6_000, sample: 4_096, bufferFrames: bufferFrames,
            to: &detector
        )
        #expect(afterReset == [.began])
        #expect(detector.isSpeaking)
    }

    @Test func incompleteSampleDoesNotAdvanceOnsetTiming() {
        var detector = VoiceOnsetDetector(minimumVoicedDuration: 0.04)
        let initial = feed(frameCount: 720, sample: 4_096, bufferFrames: 128, to: &detector)
        #expect(initial.isEmpty)

        var malformed = pcm(frameCount: 480, sample: 4_096)
        malformed.append(0)
        let ignored = detector.process(pcm16: malformed)
        #expect(ignored.isEmpty)
        #expect(!detector.isSpeaking)

        let onset = feed(frameCount: 240, sample: 4_096, bufferFrames: 128, to: &detector)
        #expect(onset == [.began])
        #expect(detector.isSpeaking)
    }

    @Test func oneBufferCanContainSeveralOnsetTransitions() {
        var detector = VoiceOnsetDetector()
        let data = pcm(frameCount: 6_000, sample: 4_096)
            + pcm(frameCount: 12_000, sample: 0)
            + pcm(frameCount: 6_000, sample: 4_096)

        let transitions = detector.process(pcm16: data)

        #expect(transitions == [.began, .ended, .began])
        #expect(detector.isSpeaking)
    }

    @Test func timedOnsetOffsetCountsOnlyFramesInTheCurrentChunk() {
        var detector = VoiceOnsetDetector()
        let pending = detector.processTimed(pcm16: pcm(frameCount: 959, sample: 4_096))
        #expect(pending.isEmpty)

        let onset = detector.processTimed(pcm16: pcm(frameCount: 1, sample: 4_096))

        #expect(onset == [VoiceOnsetDetection(transition: .began, frameOffset: 1)])
    }

    @Test func timedTransitionsPreserveTheirOffsetsWithinOneBoundedChunk() {
        var detector = VoiceOnsetDetector()
        let data = pcm(frameCount: 960, sample: 4_096)
            + pcm(frameCount: 4_800, sample: 0)
            + pcm(frameCount: 960, sample: 4_096)
        #expect(data.count == 13_440)

        let detections = detector.processTimed(pcm16: data)

        #expect(detections == [
            VoiceOnsetDetection(transition: .began, frameOffset: 960),
            VoiceOnsetDetection(transition: .ended, frameOffset: 5_760),
            VoiceOnsetDetection(transition: .began, frameOffset: 6_720),
        ])
    }

    @Test(arguments: [128, 512, 1_024, 2_048])
    func globalOnsetTimestampsAreIndependentOfCallbackSize(bufferFrames: Int) {
        var detector = VoiceOnsetDetector()
        let data = pcm(frameCount: 960, sample: 4_096)
            + pcm(frameCount: 4_800, sample: 0)
            + pcm(frameCount: 960, sample: 4_096)
        var transitions: [VoiceOnsetTransition] = []
        var globalFrames: [Int] = []

        for startFrame in stride(from: 0, to: 6_720, by: bufferFrames) {
            let endFrame = min(startFrame + bufferFrames, 6_720)
            let chunk = data.subdata(in: (startFrame * 2)..<(endFrame * 2))
            for detection in detector.processTimed(pcm16: chunk) {
                #expect(detection.frameOffset > 0)
                #expect(detection.frameOffset <= endFrame - startFrame)
                transitions.append(detection.transition)
                globalFrames.append(startFrame + detection.frameOffset)
            }
        }

        #expect(transitions == [.began, .ended, .began])
        #expect(globalFrames == [960, 5_760, 6_720])
    }

    @Test func playbackCountsOnlyCompletedAudioAndNeverExceedsScheduledFrames() {
        var playback = PlaybackAccounting()
        playback.begin()
        playback.append(frameCount: 960)
        playback.append(frameCount: 480)
        #expect(playback.playedFrameCount == 0)
        #expect(playback.playedMilliseconds == 0)

        playback.complete(frameCount: 960)
        #expect(playback.playedFrameCount == 960)
        #expect(playback.playedMilliseconds == 40)

        // Queuing more audio during a playback gap does not make it heard.
        playback.append(frameCount: 960)
        #expect(playback.playedFrameCount == 960)

        playback.complete(frameCount: 4_096)
        #expect(playback.playedFrameCount == 2_400)
        #expect(playback.playedMilliseconds == 100)
    }

    @Test func beginningPlaybackClearsPreviousCompletion() {
        var playback = PlaybackAccounting()
        playback.begin()
        playback.append(frameCount: 2_400)
        playback.complete(frameCount: 2_400)

        playback.begin()
        playback.append(frameCount: 480)

        #expect(playback.scheduledFrameCount == 480)
        #expect(playback.playedFrameCount == 0)
        #expect(playback.playedMilliseconds == 0)
    }

    private func feed(
        frameCount: Int, sample: Int16, bufferFrames: Int,
        to detector: inout VoiceOnsetDetector
    ) -> [VoiceOnsetTransition] {
        var transitions: [VoiceOnsetTransition] = []
        for start in stride(from: 0, to: frameCount, by: bufferFrames) {
            let count = min(bufferFrames, frameCount - start)
            transitions.append(contentsOf: detector.process(pcm16: pcm(frameCount: count, sample: sample)))
        }
        return transitions
    }

    private func pcm(frameCount: Int, sample: Int16) -> Data {
        let samples = Array(repeating: sample.littleEndian, count: frameCount)
        return samples.withUnsafeBytes { Data($0) }
    }
}
