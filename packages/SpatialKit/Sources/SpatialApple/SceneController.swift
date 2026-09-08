import CoreGraphics
import Foundation
import Observation
import RealityKit
import SpatialCore

#if os(iOS)
import UIKit
#endif

public enum SceneConnectionState: Sendable, Equatable {
    case disconnected
    case connecting
    case connected
    case failed(String)
}

public struct SceneSelection: Codable, Sendable, Equatable, CustomStringConvertible {
    public var nodeIDs: [String]

    public init(nodeIDs: [String]) {
        self.nodeIDs = nodeIDs
    }

    public var primaryNodeID: String? { nodeIDs.first }
    public var description: String { nodeIDs.joined(separator: ", ") }
}

public struct InstalledSceneExplanation: Sendable, Equatable {
    public var requestID: String
    public var proposalRequestIDs: [String]
    public var intentEpoch: UInt64
    public var text: String

    public init(requestID: String, proposalRequestIDs: [String], intentEpoch: UInt64, text: String) {
        self.requestID = requestID
        self.proposalRequestIDs = proposalRequestIDs
        self.intentEpoch = intentEpoch
        self.text = text
    }
}

/// Coordinates the device scene boundary: session transport, transactional
/// installation, rendered projection, selection, and pointing input.
@MainActor
@Observable
public final class SceneController {
    public private(set) var acceptedScene: SceneState
    public private(set) var connectionState: SceneConnectionState = .disconnected
    public private(set) var selection: SceneSelection?
    public private(set) var lastError: String?
    public private(set) var lastExplanation: String?
    public private(set) var activity: String?
    public private(set) var lastReceipt: ApplyReceipt?
    public private(set) var pointingUpdate: PointingResolverUpdate?

    @ObservationIgnored public let renderer: SceneRenderer
    @ObservationIgnored public var onExplanation: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onInstalledExplanation: (@MainActor (InstalledSceneExplanation) -> Void)?
    @ObservationIgnored private let transport: SceneWebSocketClient
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let wireDecoder = SceneWireDecoder()
    @ObservationIgnored private var sessionID = UUID().uuidString.lowercased()
    @ObservationIgnored private var lastConnectedURL: URL?
    @ObservationIgnored private var sessionAuthToken: String?
    @ObservationIgnored private var pointingResolver = PointingResolver()
    @ObservationIgnored private var pointingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var installedRequestIDs = Set<String>()
    #if os(iOS)
    @ObservationIgnored private var tapRelay: SceneTapGestureRelay?
    #endif

    public init() {
        let document = SceneDocument(documentId: "document_local")
        do {
            let state = try SceneState(document: document, sceneId: "scene_\(UUID().uuidString.lowercased())")
            acceptedScene = state
            renderer = SceneRenderer(initialState: state)
        } catch {
            preconditionFailure("The built-in empty scene must satisfy SpatialCore: \(error)")
        }
        transport = SceneWebSocketClient()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public init(initialState: SceneState) {
        acceptedScene = initialState
        renderer = SceneRenderer(initialState: initialState)
        transport = SceneWebSocketClient()
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public func attach(to view: ARView) {
        do {
            try renderer.attach(to: view)
            #if os(iOS)
            let relay = SceneTapGestureRelay(controller: self, view: view)
            view.addGestureRecognizer(UITapGestureRecognizer(target: relay, action: #selector(SceneTapGestureRelay.handleTap(_:))))
            tapRelay = relay
            #endif
        } catch {
            report(error)
        }
    }

    public func connect(url: URL, authToken: String? = nil) {
        guard let socketURL = websocketURL(from: url) else {
            lastError = "The session URL must use http, https, ws, or wss."
            connectionState = .failed(lastError!)
            return
        }

        connectionState = .connecting
        lastConnectedURL = socketURL
        sessionAuthToken = authToken?.isEmpty == true ? nil : authToken
        lastError = nil
        sessionID = UUID().uuidString.lowercased()
        transport.connect(
            to: socketURL,
            onMessage: { [weak self] data in
                await self?.receive(data)
            },
            onStateChange: { [weak self] state in
                guard let self else { return }
                switch state {
                case .disconnected:
                    self.connectionState = .disconnected
                case .connecting, .connected:
                    if self.connectionState != .connected {
                        self.connectionState = .connecting
                    }
                case let .failed(message):
                    self.connectionState = .failed(message)
                    self.lastError = message
                }
            }
        )

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.sendSessionHello()
                try await self.sendSnapshot()
            } catch {
                self.report(error)
            }
        }
    }

    public func disconnect() {
        transport.disconnect()
        connectionState = .disconnected
        activity = nil
    }

    public func request(text: String, selection: SceneSelection? = nil) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let validNodeIDs = (selection?.nodeIDs ?? []).filter { requestedID in
            acceptedScene.document.nodes.contains { $0.nodeId == requestedID }
        }
        let epoch = acceptedScene.advanceIntentEpoch()
        installedRequestIDs.removeAll(keepingCapacity: true)
        let fenceRequestID = "supersede_\(UUID().uuidString.lowercased())"
        let request = UserRequest(
            requestId: "request_\(UUID().uuidString.lowercased())",
            text: text,
            selection: validNodeIDs.isEmpty ? nil : .init(nodeIds: validNodeIDs)
        )
        let snapshot = makeSnapshot()
        lastExplanation = nil
        activity = "sending"
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(
                    IntentControl(
                        type: "user.stop",
                        requestId: fenceRequestID,
                        sceneId: self.acceptedScene.sceneId,
                        intentEpoch: epoch
                    ),
                    using: self.encoder
                )
                try await self.transport.send(snapshot, using: self.encoder)
                try await self.transport.send(request, using: self.encoder)
            } catch {
                self.report(error)
            }
        }
    }

    public func request(text: String, speechLock: PointingSpeechLock?) {
        let lockedSelection: SceneSelection?
        if let speechLock,
           speechLock.selection.sceneID == acceptedScene.sceneId,
           acceptedScene.document.nodes.contains(where: { $0.nodeId == speechLock.selection.nodeID })
        {
            lockedSelection = SceneSelection(nodeIDs: [speechLock.selection.nodeID])
        } else {
            lockedSelection = nil
        }
        request(text: text, selection: lockedSelection)
    }

    public func stop() {
        let epoch = acceptedScene.advanceIntentEpoch()
        installedRequestIDs.removeAll(keepingCapacity: true)
        let requestID = "stop_\(UUID().uuidString.lowercased())"
        let snapshot = makeSnapshot()
        activity = nil
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(
                    IntentControl(type: "user.stop", requestId: requestID, sceneId: self.acceptedScene.sceneId, intentEpoch: epoch),
                    using: self.encoder
                )
                try await self.transport.send(snapshot, using: self.encoder)
            } catch {
                self.report(error)
            }
        }
    }

    public func undo() {
        let requestID = "undo_\(UUID().uuidString.lowercased())"
        var candidate = acceptedScene
        let epoch = candidate.advanceIntentEpoch()
        let previewReceipt = candidate.undo(requestId: requestID)

        let prepared: PreparedScene?
        if previewReceipt.status == .installed {
            do {
                prepared = try renderer.prepareScene(candidate.document)
            } catch {
                report(error)
                return
            }
        } else {
            prepared = nil
        }

        let committedEpoch = acceptedScene.advanceIntentEpoch()
        installedRequestIDs.removeAll(keepingCapacity: true)
        guard committedEpoch == epoch else {
            report("Undo was superseded before commit.")
            return
        }
        let receipt = acceptedScene.undo(requestId: requestID)
        if receipt.status == .installed, let prepared {
            renderer.installPreparedScene(acceptedScene.document, prepared: prepared)
            lastExplanation = nil
            if let selected = selection?.primaryNodeID,
               !acceptedScene.document.nodes.contains(where: { $0.nodeId == selected })
            {
                setSelection(nil)
            }
        }
        lastReceipt = .scene(receipt)
        let snapshot = makeSnapshot()

        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.transport.send(
                    IntentControl(type: "user.undo", requestId: requestID, sceneId: self.acceptedScene.sceneId, intentEpoch: committedEpoch),
                    using: self.encoder
                )
                try await self.transport.send(receipt, using: self.encoder)
                try await self.transport.send(snapshot, using: self.encoder)
            } catch {
                self.report(error)
            }
        }
    }

    public func loadScene(_ state: SceneState) throws {
        let reconnectURL = connectionState == .disconnected ? nil : lastConnectedURL
        let prepared = try renderer.prepareScene(state.document)
        renderer.installPreparedScene(state.document, prepared: prepared)
        acceptedScene = state
        installedRequestIDs.removeAll()
        lastExplanation = nil
        pointingUpdate = pointingResolver.resetForSceneChange()
        setSelection(nil)
        if let reconnectURL {
            connect(url: reconnectURL, authToken: sessionAuthToken)
        }
    }

    public func loadScene(_ document: SceneDocument) throws {
        let state = try SceneState(
            document: document,
            sceneId: "scene_\(UUID().uuidString.lowercased())"
        )
        try loadScene(state)
    }

    @discardableResult
    public func select(at point: CGPoint) -> SceneSelection? {
        let nodeID = renderer.select(at: point)
        setSelection(nodeID.map { SceneSelection(nodeIDs: [$0]) })
        return selection
    }

    public func setSelection(_ selection: SceneSelection?) {
        self.selection = selection
        renderer.setSelection(selection?.primaryNodeID)
    }

    @discardableResult
    public func receivePointing(
        _ result: PointingScreenDetectionResult,
        now: TimeInterval = ProcessInfo.processInfo.systemUptime
    ) -> PointingResolverUpdate {
        let update: PointingResolverUpdate
        switch result {
        case let .observation(observation):
            update = pointingResolver.ingest(observation, now: now) { [renderer] point in
                renderer.nodeID(at: CGPoint(x: point.x, y: point.y)).map(PointingTarget.init(nodeID:))
            }
        case let .noHand(timestamp):
            update = pointingResolver.handLost(at: timestamp)
        case let .failed(timestamp, reason):
            update = pointingResolver.expire(at: max(timestamp, now))
            report(reason)
        }
        pointingUpdate = update
        renderer.setSelection(update.stableHover?.target.nodeID ?? selection?.primaryNodeID)
        return update
    }

    public func beginSpeech(at timestamp: TimeInterval = ProcessInfo.processInfo.systemUptime) -> PointingSpeechLock? {
        guard let lock = pointingResolver.beginSpeech(sceneID: acceptedScene.sceneId, at: timestamp),
              acceptedScene.document.nodes.contains(where: { $0.nodeId == lock.selection.nodeID })
        else {
            return nil
        }
        setSelection(SceneSelection(nodeIDs: [lock.selection.nodeID]))
        return lock
    }

    public func endSpeech(_ lock: PointingSpeechLock) {
        pointingUpdate = pointingResolver.endSpeech(lockID: lock.speechLockID)
    }

    /// Starts local expiry while hand pointing is enabled. Camera callbacks are
    /// not a liveness guarantee: Vision can stop returning results after an
    /// interruption or a stale result can be rejected without another callback.
    public func startPointingTracking() {
        guard pointingExpiryTask == nil else { return }
        pointingExpiryTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(100))
                guard !Task.isCancelled else { return }
                guard let self else { return }
                self.expirePointing(at: ProcessInfo.processInfo.systemUptime)
            }
        }
    }

    /// Stops expiry and clears temporary hand feedback. It intentionally keeps
    /// a confirmed selection and any already-bound speech request intact.
    public func stopPointingTracking() {
        pointingExpiryTask?.cancel()
        pointingExpiryTask = nil
        pointingUpdate = pointingResolver.clearTransientTracking()
        renderer.setSelection(selection?.primaryNodeID)
    }

    #if os(iOS)
    public func makePointingFrameAdapter() -> ARPointingFrameAdapter {
        startPointingTracking()
        let adapter = ARPointingFrameAdapter()
        adapter.onResult = { [weak self] result in
            self?.receivePointing(result)
        }
        return adapter
    }
    #endif

    #if os(iOS)
    @discardableResult
    public func placeScene(at point: CGPoint) -> Bool {
        renderer.placeRoot(at: point)
    }
    #endif

    func report(_ error: any Error) {
        report(error.localizedDescription)
    }

    private func expirePointing(at timestamp: TimeInterval) {
        let update = pointingResolver.expire(at: timestamp)
        guard update != pointingUpdate else { return }
        pointingUpdate = update
        renderer.setSelection(update.stableHover?.target.nodeID ?? selection?.primaryNodeID)
    }

    func report(_ message: String) {
        lastError = message
    }

    func receive(_ data: Data) async {
        do {
            let header = try decoder.decode(IncomingHeader.self, from: data)
            switch header.type {
            case "session.accepted":
                let accepted = try decoder.decode(SessionAccepted.self, from: data)
                guard accepted.protocolVersion == 1,
                      accepted.sceneSchemaVersion == 1,
                      accepted.geometrySemanticsVersion == 1,
                      accepted.sessionId == sessionID
                else {
                    throw SessionRuntimeError.incompatibleHandshake
                }
                connectionState = .connected
            case "generation.begin", "generation.batch", "generation.finish", "scene.patch":
                let message = try wireDecoder.decodeMessage(from: data)
                let result = applyIncoming(message)
                lastReceipt = result.receipt
                if case let .scene(receipt) = result.receipt, receipt.status == .installed {
                    installedRequestIDs.insert(receipt.requestId)
                }
                let snapshot = result.documentChanged ? makeSnapshot() : nil
                try await transport.send(result.receipt, using: encoder)
                if let snapshot {
                    try await transport.send(snapshot, using: encoder)
                }
            case "session.explanation":
                let explanation = try decoder.decode(SessionExplanation.self, from: data)
                guard explanation.intentEpoch == acceptedScene.intentEpoch,
                      explanation.proposalRequestIds.allSatisfy(installedRequestIDs.contains)
                else {
                    throw SessionRuntimeError.unverifiedExplanation
                }
                lastExplanation = explanation.text
                activity = nil
                onExplanation?(explanation.text)
                onInstalledExplanation?(InstalledSceneExplanation(
                    requestID: explanation.requestId,
                    proposalRequestIDs: explanation.proposalRequestIds,
                    intentEpoch: explanation.intentEpoch,
                    text: explanation.text
                ))
            case "session.progress":
                let progress = try decoder.decode(SessionProgress.self, from: data)
                guard progress.intentEpoch == acceptedScene.intentEpoch else { return }
                activity = progress.status
            case "session.model_text":
                // Model deltas are intentionally not user-visible evidence of an installed scene.
                break
            case "session.error":
                let serviceError = try decoder.decode(SessionErrorMessage.self, from: data)
                lastError = "\(serviceError.code): \(serviceError.message)"
                activity = nil
            default:
                throw SessionRuntimeError.unsupportedMessage(header.type)
            }
        } catch {
            report(error)
        }
    }

    private func applyIncoming(_ message: ClientMessage) -> IncomingResult {
        let startingRevision = acceptedScene.revision
        let startingEpoch = acceptedScene.intentEpoch
        let startingDocument = acceptedScene.document
        var candidate = acceptedScene
        let previewReceipt = candidate.apply(message)

        let prepared: PreparedScene?
        if previewReceipt.installedScene, candidate.document != startingDocument {
            do {
                prepared = try renderer.prepareScene(candidate.document)
            } catch {
                return IncomingResult(
                    receipt: .scene(renderRejection(from: previewReceipt, error: error)),
                    documentChanged: false
                )
            }
        } else {
            prepared = nil
        }

        guard acceptedScene.revision == startingRevision, acceptedScene.intentEpoch == startingEpoch else {
            return IncomingResult(
                receipt: .scene(staleCommitRejection(for: message)),
                documentChanged: false
            )
        }

        let receipt = acceptedScene.apply(message)
        let documentChanged = receipt.installedScene && acceptedScene.document != startingDocument
        if documentChanged, let prepared {
            renderer.installPreparedScene(acceptedScene.document, prepared: prepared)
            lastExplanation = nil
        }
        return IncomingResult(receipt: receipt, documentChanged: documentChanged)
    }

    private func renderRejection(from receipt: ApplyReceipt, error: any Error) -> SceneReceipt {
        let identity = receipt.sceneIdentity
        return SceneReceipt(
            sceneId: acceptedScene.sceneId,
            generationId: identity.generationID,
            requestId: identity.requestID,
            sequence: identity.sequence,
            status: .rejected,
            revision: acceptedScene.revision,
            rejection: Rejection(code: "native_preparation_failed", message: error.localizedDescription)
        )
    }

    private func staleCommitRejection(for message: ClientMessage) -> SceneReceipt {
        let identity = message.sceneIdentity
        return SceneReceipt(
            sceneId: acceptedScene.sceneId,
            generationId: identity.generationID,
            requestId: identity.requestID,
            sequence: identity.sequence,
            status: .rejected,
            revision: acceptedScene.revision,
            rejection: Rejection(
                code: "native_commit_superseded",
                message: "Scene state changed while native resources were prepared.",
                expectedRevision: acceptedScene.revision
            )
        )
    }

    private func sendSessionHello() async throws {
        try await transport.send(
            SessionHello(
                sessionId: sessionID,
                sceneId: acceptedScene.sceneId,
                revision: acceptedScene.revision,
                intentEpoch: acceptedScene.intentEpoch,
                authToken: sessionAuthToken
            ),
            using: encoder
        )
    }

    private func sendSnapshot() async throws {
        try await transport.send(makeSnapshot(), using: encoder)
    }

    private func makeSnapshot() -> PhoneSnapshot {
        PhoneSnapshot(
            sceneId: acceptedScene.sceneId,
            revision: acceptedScene.revision,
            intentEpoch: acceptedScene.intentEpoch,
            document: acceptedScene.document
        )
    }

    private func websocketURL(from url: URL) -> URL? {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        switch components.scheme?.lowercased() {
        case "http": components.scheme = "ws"
        case "https": components.scheme = "wss"
        case "ws", "wss": break
        default: return nil
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/session"
        }
        return components.url
    }
}

private struct IncomingResult {
    var receipt: ApplyReceipt
    var documentChanged: Bool
}

private enum SessionRuntimeError: LocalizedError {
    case incompatibleHandshake
    case unsupportedMessage(String)
    case unverifiedExplanation

    var errorDescription: String? {
        switch self {
        case .incompatibleHandshake:
            "The session service selected an incompatible protocol."
        case let .unsupportedMessage(type):
            "The session service sent unsupported message type \(type)."
        case .unverifiedExplanation:
            "The session explanation does not match installed receipts in the current epoch."
        }
    }
}

private extension ApplyReceipt {
    var installedScene: Bool {
        if case let .scene(receipt) = self {
            return receipt.status == .installed
        }
        return false
    }

    var sceneIdentity: (requestID: String, generationID: String?, sequence: UInt64?) {
        switch self {
        case let .scene(receipt):
            (receipt.requestId, receipt.generationId, receipt.sequence)
        case let .generation(receipt):
            (receipt.requestId, receipt.generationId, nil)
        }
    }
}

private extension ClientMessage {
    var sceneIdentity: (requestID: String, generationID: String?, sequence: UInt64?) {
        switch self {
        case .hello:
            ("", nil, nil)
        case let .generationBegin(value):
            (value.requestId, value.generationId, nil)
        case let .generationBatch(value):
            (value.requestId, value.generationId, value.sequence)
        case let .generationFinish(value):
            (value.requestId, value.generationId, nil)
        case let .scenePatch(value):
            (value.requestId, nil, nil)
        }
    }
}
