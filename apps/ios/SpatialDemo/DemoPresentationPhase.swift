import Foundation

/// Each phase reflects work the client or service has actually reported.
enum DemoPresentationPhase: Equatable {
    case ready, connecting, listening, thinking, generating, constructing
    case downloading, loadingAsset, processing, responding
    case failed(String)

    var label: String {
        switch self {
        case .ready: ""
        case .connecting: "Connecting…"
        case .listening: "Listening…"
        case .thinking: "Thinking…"
        case .generating: "Generating…"
        case .constructing: "Constructing…"
        case .downloading: "Downloading the rack…"
        case .loadingAsset: "Loading details…"
        case .processing: "Processing…"
        case .responding: "Responding…"
        case let .failed(message): message
        }
    }

    var isAnimating: Bool {
        switch self {
        case .ready, .failed: false
        default: true
        }
    }
}
