import Foundation

/// A small message transport. It intentionally knows nothing about RealityKit or scene state.
@MainActor
public final class SceneWebSocketClient {
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

        public var errorDescription: String? {
            switch self {
            case .notConnected:
                "The scene service is not connected."
            case .unsupportedMessage:
                "The scene service sent an unsupported WebSocket message."
            case let .messageTooLarge(actualBytes, limitBytes):
                "The scene service sent \(actualBytes) bytes; the limit is \(limitBytes)."
            }
        }
    }

    public private(set) var state: State = .disconnected

    private let maximumMessageBytes: Int
    private var socket: URLSessionWebSocketTask?
    private var receiveTask: Task<Void, Never>?
    private var onMessage: (@MainActor (Data) async -> Void)?
    private var onStateChange: (@MainActor (State) -> Void)?

    public init(maximumMessageBytes: Int = 256 * 1_024) {
        self.maximumMessageBytes = maximumMessageBytes
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

        let socket = URLSession.shared.webSocketTask(with: url)
        socket.maximumMessageSize = maximumMessageBytes
        self.socket = socket
        socket.resume()
        setState(.connected)

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
        try await socket.send(.string(String(decoding: data, as: UTF8.self)))
    }

    public func send<Value: Encodable>(_ value: Value, using encoder: JSONEncoder = JSONEncoder()) async throws {
        try await send(encoder.encode(value))
    }

    public func disconnect() {
        receiveTask?.cancel()
        receiveTask = nil
        socket?.cancel(with: .goingAway, reason: nil)
        socket = nil
        onMessage = nil
        if state != .disconnected {
            setState(.disconnected)
        }
    }

    private func receiveMessages(from socket: URLSessionWebSocketTask) async {
        do {
            while !Task.isCancelled {
                let message = try await socket.receive()
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
                await onMessage?(data)
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, self.socket === socket else {
                return
            }
            self.socket = nil
            setState(.failed(error.localizedDescription))
        }
    }

    private func setState(_ state: State) {
        self.state = state
        onStateChange?(state)
    }
}
