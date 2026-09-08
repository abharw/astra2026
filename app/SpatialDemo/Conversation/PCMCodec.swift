import Foundation

enum PCMCodec {
    nonisolated static let sampleRate = 24_000
    nonisolated static let bytesPerFrame = 2

    static func frameCount(inPCM16 data: Data) throws -> Int {
        guard data.count.isMultiple(of: bytesPerFrame) else {
            throw VoiceSessionError.realtime("Received an incomplete PCM16 sample.")
        }
        return data.count / bytesPerFrame
    }
}

/// Pure playback math kept separate from AVAudioEngine so interruption cutoffs
/// can be verified without a device audio route.
struct PlaybackAccounting: Equatable, Sendable {
    private(set) var scheduledFrameCount = 0
    private(set) var playedFrameCount = 0

    mutating func begin() {
        scheduledFrameCount = 0
        playedFrameCount = 0
    }

    mutating func append(frameCount: Int) {
        scheduledFrameCount += max(0, frameCount)
    }

    mutating func complete(frameCount: Int) {
        playedFrameCount = min(scheduledFrameCount, playedFrameCount + max(0, frameCount))
    }

    /// Only completed buffers count as heard. A player clock also advances
    /// through underrun gaps, so it cannot safely determine truncation offsets.
    var playedMilliseconds: Int { playedFrameCount * 1_000 / PCMCodec.sampleRate }
}

struct PlaybackCut: Equatable, Sendable {
    let itemID: String
    let contentIndex: Int
    let playedMilliseconds: Int
}

nonisolated enum VoiceOnsetTransition: Equatable, Sendable {
    case began
    case ended
}

nonisolated struct VoiceOnsetDetection: Equatable, Sendable {
    let transition: VoiceOnsetTransition
    /// Frames consumed in this chunk when the analysis window completed.
    let frameOffset: Int
}

/// A deliberately small local onset gate used only to timestamp and bind the
/// current selection before cloud VAD returns an item ID. Realtime remains the
/// authority for turn boundaries and transcription.
struct VoiceOnsetDetector: Sendable {
    private let beginRMS: Double
    private let endRMS: Double
    private let voicedFramesRequired: Int
    private let quietFramesRequired: Int
    private static let analysisWindowFrames = PCMCodec.sampleRate / 100
    private(set) var isSpeaking = false
    private var voicedFrames = 0
    private var quietFrames = 0
    private var windowFrames = 0
    private var windowSquareSum = 0.0

    var onsetWindowToleranceFrames: Int {
        ((voicedFramesRequired + Self.analysisWindowFrames - 1) / Self.analysisWindowFrames + 1)
            * Self.analysisWindowFrames
    }

    init(
        beginRMS: Double = 0.028,
        endRMS: Double = 0.016,
        minimumVoicedDuration: TimeInterval = 0.04,
        minimumQuietDuration: TimeInterval = 0.2
    ) {
        precondition(minimumVoicedDuration.isFinite && minimumVoicedDuration > 0)
        precondition(minimumQuietDuration.isFinite && minimumQuietDuration > 0)
        self.beginRMS = beginRMS
        self.endRMS = endRMS
        voicedFramesRequired = Int(ceil(minimumVoicedDuration * Double(PCMCodec.sampleRate)))
        quietFramesRequired = Int(ceil(minimumQuietDuration * Double(PCMCodec.sampleRate)))
    }

    /// Analyze fixed 10ms windows across callback boundaries. A large callback
    /// can contain more than one transition, so no boundary is discarded.
    mutating func process(pcm16 data: Data) -> [VoiceOnsetTransition] {
        processTimed(pcm16: data).map(\.transition)
    }

    mutating func processTimed(pcm16 data: Data) -> [VoiceOnsetDetection] {
        guard data.count.isMultiple(of: PCMCodec.bytesPerFrame) else { return [] }
        var detections: [VoiceOnsetDetection] = []
        data.withUnsafeBytes { bytes in
            for offset in stride(from: 0, to: data.count, by: PCMCodec.bytesPerFrame) {
                let raw = bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                let sample = Double(Int16(littleEndian: raw)) / 32_768.0
                windowSquareSum += sample * sample
                windowFrames += 1
                guard windowFrames == Self.analysisWindowFrames else { continue }
                let rms = sqrt(windowSquareSum / Double(windowFrames))
                if isSpeaking {
                    quietFrames = rms < endRMS ? quietFrames + windowFrames : 0
                    if quietFrames >= quietFramesRequired {
                        isSpeaking = false
                        quietFrames = 0
                        voicedFrames = 0
                        detections.append(VoiceOnsetDetection(
                            transition: .ended, frameOffset: offset / PCMCodec.bytesPerFrame + 1
                        ))
                    }
                } else {
                    voicedFrames = rms >= beginRMS ? voicedFrames + windowFrames : 0
                    if voicedFrames >= voicedFramesRequired {
                        isSpeaking = true
                        voicedFrames = 0
                        quietFrames = 0
                        detections.append(VoiceOnsetDetection(
                            transition: .began, frameOffset: offset / PCMCodec.bytesPerFrame + 1
                        ))
                    }
                }
                windowFrames = 0
                windowSquareSum = 0
            }
        }
        return detections
    }

    mutating func reset() {
        isSpeaking = false
        voicedFrames = 0
        quietFrames = 0
        windowFrames = 0
        windowSquareSum = 0
    }
}
