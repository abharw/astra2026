import Foundation

nonisolated struct MicrophoneChunk: Sendable {
    let captureID: UUID
    let data: Data
}

nonisolated struct AudioCapture: Sendable {
    let sessionID: UUID
    let route: AudioRouteReport
    let stream: AsyncThrowingStream<MicrophoneChunk, Error>
}

@MainActor
protocol RealtimeAudioIO: AnyObject {
    var currentCaptureID: UUID? { get }
    func rotateCaptureID() -> UUID?
    func start() throws -> AudioCapture
    func stop()
    func enqueuePlayback(_ data: Data, itemID: String, contentIndex: Int) throws
    func markOutputComplete(itemID: String)
    @discardableResult func interruptPlayback() -> PlaybackCut?
}

extension AudioIOController: RealtimeAudioIO {}

@MainActor
protocol RealtimeSocket: AnyObject {
    var maximumMessageSize: Int { get set }
    func resume()
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?)
    func receive() async throws -> URLSessionWebSocketTask.Message
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    )
}

@MainActor
private final class URLSessionRealtimeSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    var maximumMessageSize: Int {
        get { task.maximumMessageSize }
        set { task.maximumMessageSize = newValue }
    }

    func resume() { task.resume() }
    func cancel(with closeCode: URLSessionWebSocketTask.CloseCode, reason: Data?) {
        task.cancel(with: closeCode, reason: reason)
    }
    func receive() async throws -> URLSessionWebSocketTask.Message { try await task.receive() }
    func send(
        _ message: URLSessionWebSocketTask.Message,
        completionHandler: @escaping @Sendable (Error?) -> Void
    ) {
        task.send(message, completionHandler: completionHandler)
    }
}

/// The same session logic runs against native I/O and deterministic test I/O.
@MainActor
struct RealtimeDependencies {
    var fetchCredentialData: @MainActor (URLRequest) async throws -> (Data, URLResponse)
    var makeSocket: @MainActor (URLRequest) -> any RealtimeSocket
    var makeAudioIO: @MainActor (@escaping @MainActor (AudioIOEvent) -> Void) -> any RealtimeAudioIO
    var requestMicrophonePermission: @MainActor () async -> Bool

    static var live: RealtimeDependencies {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        let session = URLSession(configuration: configuration)
        return RealtimeDependencies(
            fetchCredentialData: { try await session.data(for: $0) },
            makeSocket: { URLSessionRealtimeSocket(session.webSocketTask(with: $0)) },
            makeAudioIO: { AudioIOController(onEvent: $0) },
            requestMicrophonePermission: { await AudioIOController.requestMicrophonePermission() }
        )
    }
}
