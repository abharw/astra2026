import Foundation

enum PCMCodec {
    static let sampleRate = 24_000
    static let bytesPerFrame = 2

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
    private(set) var startSampleTime: Int64?

    mutating func begin(at sampleTime: Int64) {
        scheduledFrameCount = 0
        startSampleTime = sampleTime
    }

    mutating func append(frameCount: Int) {
        scheduledFrameCount += max(0, frameCount)
    }

    func playedFrameCount(at sampleTime: Int64) -> Int {
        guard let startSampleTime else { return 0 }
        let elapsed = max(0, sampleTime - startSampleTime)
        return min(scheduledFrameCount, Int(elapsed))
    }

    func playedMilliseconds(at sampleTime: Int64) -> Int {
        playedFrameCount(at: sampleTime) * 1_000 / PCMCodec.sampleRate
    }
}

struct PlaybackCut: Equatable, Sendable {
    let itemID: String
    let contentIndex: Int
    let playedMilliseconds: Int
}

enum VoiceOnsetTransition: Equatable, Sendable {
    case began
    case ended
}

/// A deliberately small local onset gate used only to timestamp and bind the
/// current selection before cloud VAD returns an item ID. Realtime remains the
/// authority for turn boundaries and transcription.
struct VoiceOnsetDetector: Sendable {
    private let beginRMS: Double
    private let endRMS: Double
    private let voicedChunksRequired: Int
    private let quietChunksRequired: Int
    private(set) var isSpeaking = false
    private var voicedChunks = 0
    private var quietChunks = 0

    init(
        beginRMS: Double = 0.028,
        endRMS: Double = 0.016,
        voicedChunksRequired: Int = 2,
        quietChunksRequired: Int = 10
    ) {
        self.beginRMS = beginRMS
        self.endRMS = endRMS
        self.voicedChunksRequired = voicedChunksRequired
        self.quietChunksRequired = quietChunksRequired
    }

    mutating func process(pcm16 data: Data) -> VoiceOnsetTransition? {
        let rms = Self.rms(pcm16: data)
        if isSpeaking {
            if rms < endRMS {
                quietChunks += 1
                if quietChunks >= quietChunksRequired {
                    isSpeaking = false
                    quietChunks = 0
                    voicedChunks = 0
                    return .ended
                }
            } else {
                quietChunks = 0
            }
            return nil
        }

        if rms >= beginRMS {
            voicedChunks += 1
            if voicedChunks >= voicedChunksRequired {
                isSpeaking = true
                voicedChunks = 0
                quietChunks = 0
                return .began
            }
        } else {
            voicedChunks = 0
        }
        return nil
    }

    mutating func reset() {
        self = VoiceOnsetDetector(
            beginRMS: beginRMS,
            endRMS: endRMS,
            voicedChunksRequired: voicedChunksRequired,
            quietChunksRequired: quietChunksRequired
        )
    }

    static func rms(pcm16 data: Data) -> Double {
        let frameCount = data.count / PCMCodec.bytesPerFrame
        guard frameCount > 0 else { return 0 }
        let sum = data.withUnsafeBytes { bytes -> Double in
            var total = 0.0
            for offset in stride(from: 0, to: frameCount * 2, by: 2) {
                let raw = bytes.loadUnaligned(fromByteOffset: offset, as: Int16.self)
                let normalized = Double(Int16(littleEndian: raw)) / 32_768.0
                total += normalized * normalized
            }
            return total
        }
        return sqrt(sum / Double(frameCount))
    }
}
