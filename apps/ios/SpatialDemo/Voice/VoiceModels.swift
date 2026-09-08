import Foundation

enum VoiceSessionState: Equatable, Sendable {
    case idle
    case requestingPermission
    case fetchingCredential
    case connecting
    case listening
    case speaking
    case interrupted
    case reconfiguringAudio
    case failed(String)

    var statusText: String {
        switch self {
        case .idle: "Voice off"
        case .requestingPermission: "Requesting microphone access…"
        case .fetchingCredential: "Authorizing voice…"
        case .connecting: "Connecting voice…"
        case .listening: "Listening"
        case .speaking: "Astra is speaking"
        case .interrupted: "Voice interrupted"
        case .reconfiguringAudio: "Reconfiguring audio…"
        case let .failed(message): "Voice unavailable: \(message)"
        }
    }
}

struct AudioRouteReport: Equatable, Sendable {
    let inputSampleRate: Double
    let inputChannelCount: Int
    let inputPortTypes: [String]
    let outputPortTypes: [String]
    let voiceProcessingEnabled: Bool

    var summary: String {
        let input = inputPortTypes.isEmpty ? "no input" : inputPortTypes.joined(separator: ", ")
        let output = outputPortTypes.isEmpty ? "no output" : outputPortTypes.joined(separator: ", ")
        let rate = Int(inputSampleRate.rounded())
        let processing = voiceProcessingEnabled ? "voice processing on" : "voice processing unavailable"
        return "\(input) → \(output), \(rate) Hz/\(inputChannelCount) ch, \(processing)"
    }
}

struct VoiceSessionConfiguration: Sendable {
    let backendBaseURL: URL
    let sessionID: String
    let sessionAuthToken: String?

    init(backendBaseURL: URL, sessionID: String, sessionAuthToken: String? = nil) {
        self.backendBaseURL = backendBaseURL
        self.sessionID = sessionID
        self.sessionAuthToken = sessionAuthToken
    }
}

/// A local selection snapshot taken when the microphone PCM onset gate fires.
struct VoiceSpeechBinding: Equatable, Sendable {
    let requestID: String
    let nodeIDs: [String]
    let beganAt: Date
}

struct VoiceUtterance: Equatable, Sendable {
    let requestID: String
    let text: String
    let nodeIDs: [String]
    let beganAt: Date
}

/// Receipt-backed narration from Astra. The app's narration gate decides whether
/// the required intent epoch and nodes still describe the installed scene.
struct VoiceNarrationCue: Equatable, Sendable {
    let requestID: String
    let intentEpoch: Int
    let requiredNodeIDs: [String]
    let text: String

    init(requestID: String, intentEpoch: Int, requiredNodeIDs: [String], text: String) {
        self.requestID = requestID
        self.intentEpoch = intentEpoch
        self.requiredNodeIDs = requiredNodeIDs
        self.text = text
    }
}

enum VoiceSessionError: LocalizedError {
    case invalidBackendURL
    case microphoneDenied
    case microphoneUnavailable
    case malformedCredentialResponse
    case credentialExpired
    case backend(Int, String)
    case realtime(String)
    case disconnected

    var errorDescription: String? {
        switch self {
        case .invalidBackendURL:
            "The session backend URL is invalid."
        case .microphoneDenied:
            "Microphone access is denied. Enable it in Settings to use voice."
        case .microphoneUnavailable:
            "No usable microphone input is available on this device or simulator."
        case .malformedCredentialResponse:
            "The session service returned an invalid Realtime credential."
        case .credentialExpired:
            "The Realtime credential expired before the connection opened."
        case let .backend(status, detail):
            "The session service returned HTTP \(status): \(detail)"
        case let .realtime(detail):
            "Realtime reported an error: \(detail)"
        case .disconnected:
            "The Realtime connection closed unexpectedly."
        }
    }
}
