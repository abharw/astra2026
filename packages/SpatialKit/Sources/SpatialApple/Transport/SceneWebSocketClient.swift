import Foundation

@MainActor
public protocol SceneTransport: AnyObject {
    var state: SceneWebSocketClient.State { get }

    func connect(
        to url: URL,
        onMessage: @escaping @MainActor (Data) async -> Void,
        onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void
    )
    func send(_ data: Data) async throws
    func disconnect()
}

public extension SceneTransport {
    func send<Value: Encodable>(_ value: Value, using encoder: JSONEncoder = JSONEncoder()) async throws {
        try await send(encoder.encode(value))
    }
}

/// A small message transport. It intentionally knows nothing about RealityKit or scene state.
@MainActor
public final class SceneWebSocketClient: SceneTransport {
    public enum State: Sendable, Equatable {
        case disconnected
        case connecting
        case connected
        case failed(String)
    }

    public enum TransportError: LocalizedError {
        case notConnected
        case unsupportedMessage
        case messageTooLarge(actualBytes: Int, limitBytes: Int)
        case sendTimedOut

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                "The scene service is not connected."
            case .unsupportedMessage:
                "The scene service sent an unsupported WebSocket message."
            case let .messageTooLarge(actualBytes, limitBytes):
                "The scene service sent \(actualBytes) bytes; the limit is \(limitBytes)."
            case .sendTimedOut:
                "Sending to the scene service timed out. Check the backend connection and try again."
            }
        }
    }

    public private(set) var state: State = .disconnected

    private let maximumMessageBytes: Int
    private let sendTimeout: Duration
    private var socket: URLSessionWebSocketTask?
    private var connectionID: UUID?
    private var session: URLSession?
    private var delegate: WebSocketDelegate?
    private var receiveTask: Task<Void, Never>?
    private var onMessage: (@MainActor (Data) async -> Void)?
    private var onStateChange: (@MainActor (State) -> Void)?

    public init(maximumMessageBytes: Int = 256 * 1_024, sendTimeout: Duration = .seconds(8)) {
        self.maximumMessageBytes = maximumMessageBytes
        self.sendTimeout = sendTimeout
    }

    public func connect(
        to url: URL,
        onMessage: @escaping @MainActor (Data) async -> Void,
        onStateChange: @escaping @MainActor (State) -> Void
    ) {
        disconnect()

        self.onMessage = onMessage
        self.onStateChange = onStateChange
        setState(.connecting)

        let connectionID = UUID()
        self.connectionID = connectionID
        let delegate = WebSocketDelegate(
            onOpen: { [weak self] in self?.socketDidOpen(connectionID: connectionID) },
            onClose: { [weak self] reason in self?.socketDidClose(connectionID: connectionID, reason: reason) }
        )
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = maximumMessageBytes
        self.delegate = delegate
        self.session = session
        self.socket = socket
        socket.resume()

        DiagnosticsLog.shared.record("connect.started", component: "scene.transport", fields: ["url_host": url.host ?? "unknown"])

        receiveTask = Task { [weak self] in
            await self?.receiveMessages(from: socket)
        }
    }

    public func send(_ data: Data) async throws {
        guard data.count <= maximumMessageBytes else {
            throw TransportError.messageTooLarge(
                actualBytes: data.count,
                limitBytes: maximumMessageBytes
            )
        }
        guard let socket else {
            throw TransportError.notConnected
        }
        guard state == .connected else {
            throw TransportError.notConnected
        }
        let frameType = Self.frameType(in: data)
        let gate = WebSocketSendGate()
        do {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    gate.install(continuation)
                    socket.send(.string(String(decoding: data, as: UTF8.self))) { error in
                        if let error {
                            gate.resolve(.failure(error))
                        } else {
                            gate.resolve(.success(()))
                        }
                    }
                    Task { [sendTimeout] in
                        try? await Task.sleep(for: sendTimeout)
                        guard !Task.isCancelled else { return }
                        gate.resolve(.failure(TransportError.sendTimedOut))
                    }
                }
            } onCancel: {
                gate.resolve(.failure(CancellationError()))
            }
            DiagnosticsLog.shared.record("frame.sent", component: "scene.transport", fields: ["type": frameType, "bytes": "\(data.count)"])
        } catch {
            DiagnosticsLog.shared.record("frame.send_failed", component: "scene.transport", level: .error, fields: ["type": frameType, "bytes": "\(data.count)", "error": error.localizedDescription])
            throw error
        }
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        connectionID = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        onMessage = nil
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
                guard !Task.isCancelled, self.socket === socket else { return }
                let data: Data
                switch message {
                case let .data(receivedData):
                    data = receivedData
                case let .string(string):
                    guard let utf8 = string.data(using: .utf8) else {
                        throw TransportError.unsupportedMessage
                    }
                    data = utf8
                @unknown default:
                    throw TransportError.unsupportedMessage
                }

                guard data.count <= maximumMessageBytes else {
                    throw TransportError.messageTooLarge(
                        actualBytes: data.count,
                        limitBytes: maximumMessageBytes
                    )
                }
                guard !Task.isCancelled, self.socket === socket else { return }
                DiagnosticsLog.shared.record("frame.received", component: "scene.transport", fields: ["type": Self.frameType(in: data), "bytes": "\(data.count)"])
                await onMessage?(data)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.socket === socket else {
                return
            }
            self.socket = nil
            self.connectionID = nil
            self.session?.invalidateAndCancel()
            self.session = nil
            self.delegate = nil
            DiagnosticsLog.shared.record("receive.failed", component: "scene.transport", level: .error, fields: ["error": error.localizedDescription])
            setState(.failed(error.localizedDescription))
        }
    }

    private func socketDidOpen(connectionID: UUID) {
        guard self.connectionID == connectionID, socket != nil else { return }
        DiagnosticsLog.shared.record("connect.open", component: "scene.transport")
        setState(.connected)
    }

    private func socketDidClose(connectionID: UUID, reason: String) {
        guard self.connectionID == connectionID, socket != nil else { return }
        socket = nil
        self.connectionID = nil
        receiveTask?.cancel()
        receiveTask = nil
        session?.invalidateAndCancel()
        session = nil
        delegate = nil
        DiagnosticsLog.shared.record("connect.closed", component: "scene.transport", level: .warning, fields: ["reason": reason])
        setState(.failed(reason))
    }

    private static func frameType(in data: Data) -> String {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return "unknown" }
        return type
    }

    private func setState(_ state: State) {
        self.state = state
        onStateChange?(state)
    }
}

private final class WebSocketSendGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, any Error>?
    private var result: Result<Void, any Error>?

    func install(_ continuation: CheckedContinuation<Void, any Error>) {
        lock.lock()
        if let result {
            lock.unlock()
            continuation.resume(with: result)
        } else {
            self.continuation = continuation
            lock.unlock()
        }
    }

    func resolve(_ result: Result<Void, any Error>) {
        lock.lock()
        guard self.result == nil else {
            lock.unlock()
            return
        }
        self.result = result
        let continuation = continuation
        self.continuation = nil
        lock.unlock()
        continuation?.resume(with: result)
    }
}

private final class WebSocketDelegate: NSObject, URLSessionWebSocketDelegate, @unchecked Sendable {
    private let onOpen: @MainActor @Sendable () -> Void
    private let onClose: @MainActor @Sendable (String) -> Void

    init(
        onOpen: @escaping @MainActor @Sendable () -> Void,
        onClose: @escaping @MainActor @Sendable (String) -> Void
    ) {
        self.onOpen = onOpen
        self.onClose = onClose
    }
    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didOpenWithProtocol protocol: String?
    ) {
        Task { @MainActor in onOpen() }
    }

    nonisolated func urlSession(
        _ session: URLSession,
        webSocketTask: URLSessionWebSocketTask,
        didCloseWith closeCode: URLSessionWebSocketTask.CloseCode,
        reason: Data?
    ) {
        let summary = "WebSocket closed (code \(closeCode.rawValue))."
        Task { @MainActor in onClose(summary) }
    }
}
