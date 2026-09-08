import Foundation

enum RealtimeActivity: Equatable, Sendable {
    case idle, fetchingCredential, connecting, ready, requestingPermission
    case listening, waitingForAstra, delivering, interrupted, reconfiguringAudio
    case failed(String)

    var statusText: String {
        switch self {
        case .idle: "Disconnected"
        case .fetchingCredential: "Authorizing…"
        case .connecting: "Connecting…"
        case .ready: "Ready"
        case .requestingPermission: "Requesting microphone access…"
        case .listening: "Listening"
        case .waitingForAstra: "Working with Astra…"
        case .delivering: "Astra is responding"
        case .interrupted: "Interrupted"
        case .reconfiguringAudio: "Reconfiguring audio…"
        case let .failed(message): "Unavailable: \(message)"
        }
    }

    var diagnosticName: String {
        switch self {
        case .idle: "idle"
        case .fetchingCredential: "fetching_credential"
        case .connecting: "connecting"
        case .ready: "ready"
        case .requestingPermission: "requesting_permission"
        case .listening: "listening"
        case .waitingForAstra: "waiting_for_astra"
        case .delivering: "delivering"
        case .interrupted: "interrupted"
        case .reconfiguringAudio: "reconfiguring_audio"
        case .failed: "failed"
        }
    }
}

enum RealtimeInputSource: String, Codable, Sendable { case typed, voice }

enum RealtimeSceneOutcome: String, Codable, Sendable {
    case confirmedInstalled = "confirmed_installed"
    case completedNoChange = "completed_no_change"
    case failed
    case cancelled
    case unknown
}

struct RealtimeSceneToolRequest: Equatable, Sendable {
    let requestID: String
    let text: String
    let nodeIDs: [String]
    let source: RealtimeInputSource
}

struct RealtimeSceneToolResult: Codable, Equatable, Sendable {
    let status: String
    let outcome: RealtimeSceneOutcome
    let requestID: String
    let sceneID: String?
    let revision: Int?
    let intentEpoch: Int?
    let proposalRequestIDs: [String]
    let explanation: String?
    let error: String?

    init(
        status: String,
        requestID: String,
        sceneID: String? = nil,
        revision: Int? = nil,
        intentEpoch: Int? = nil,
        proposalRequestIDs: [String] = [],
        explanation: String? = nil,
        error: String? = nil
    ) {
        self.status = status
        switch status {
        case "completed" where !proposalRequestIDs.isEmpty:
            outcome = .confirmedInstalled
        case "completed":
            outcome = .completedNoChange
        case "failed":
            outcome = .failed
        case "cancelled":
            outcome = .cancelled
        default:
            outcome = .unknown
        }
        self.requestID = requestID
        self.sceneID = sceneID
        self.revision = revision
        self.intentEpoch = intentEpoch
        self.proposalRequestIDs = proposalRequestIDs
        self.explanation = explanation
        self.error = error
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
        let processing = voiceProcessingEnabled ? "voice processing on" : "voice processing unavailable"
        return "\(input) → \(output), \(Int(inputSampleRate.rounded())) Hz/\(inputChannelCount) ch, \(processing)"
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

struct VoiceSpeechBinding: Equatable, Sendable {
    let requestID: String
    let nodeIDs: [String]
    let beganAt: Date
}

enum VoiceSessionError: LocalizedError {
    case invalidBackendURL, microphoneDenied, microphoneUnavailable
    case malformedCredentialResponse, credentialExpired, disconnected, invalidToolCall
    case backend(Int)
    case realtime(String)

    var errorDescription: String? {
        switch self {
        case .invalidBackendURL: "The session backend URL is invalid."
        case .microphoneDenied: "Microphone access is denied. Enable it in Settings to use voice."
        case .microphoneUnavailable: "No usable microphone input is available on this device or simulator."
        case .malformedCredentialResponse: "The session service returned an invalid Realtime credential."
        case .credentialExpired: "The Realtime credential expired before the connection opened."
        case let .backend(status): "The session service returned HTTP \(status)."
        case let .realtime(detail): "Realtime reported an error: \(detail)"
        case .disconnected: "The Realtime connection closed unexpectedly."
        case .invalidToolCall: "Realtime returned an invalid Astra request."
        }
    }
}
