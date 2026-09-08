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

public enum SceneExecutionStatus: String, Sendable, Equatable {
    case completed
    case failed
    case cancelled
}

public struct SceneExecutionResult: Sendable, Equatable {
    public var requestID: String
    public var status: SceneExecutionStatus
    public var sceneID: String
    public var revision: UInt64
    public var intentEpoch: UInt64
    public var proposalRequestIDs: [String]
    public var explanation: String?
    public var error: String?

    public init(
        requestID: String,
        status: SceneExecutionStatus,
        sceneID: String,
        revision: UInt64,
        intentEpoch: UInt64,
        proposalRequestIDs: [String] = [],
        explanation: String? = nil,
        error: String? = nil
    ) {
        self.requestID = requestID
        self.status = status
        self.sceneID = sceneID
        self.revision = revision
        self.intentEpoch = intentEpoch
        self.proposalRequestIDs = proposalRequestIDs
        self.explanation = explanation
        self.error = error
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
    public private(set) var illustrationEnabled = false
    public var illustration: IllustrationPresentation? { illustrationSession.presentation }

    @ObservationIgnored public let renderer: SceneRenderer
    @ObservationIgnored public var onExplanation: (@MainActor (String) -> Void)?
    @ObservationIgnored public var onInstalledExplanation: (@MainActor (InstalledSceneExplanation) -> Void)?
    @ObservationIgnored private let transport: any SceneTransport
    @ObservationIgnored private let encoder: JSONEncoder
    @ObservationIgnored private let decoder: JSONDecoder
    @ObservationIgnored private let wireDecoder = SceneWireDecoder()
    @ObservationIgnored private var sessionID = UUID().uuidString.lowercased()
    @ObservationIgnored private var lastConnectedURL: URL?
    @ObservationIgnored private var sessionAuthToken: String?
    @ObservationIgnored private var pointingResolver = PointingResolver()
    @ObservationIgnored private var pointingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var installedRequestIDs = Set<String>()
    @ObservationIgnored private let responseTimeout: Duration
    @ObservationIgnored private var responseDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var requestSendTask: Task<Void, Never>?
    @ObservationIgnored private var connectionDeadlineTask: Task<Void, Never>?
    @ObservationIgnored private var activeRequest: ActiveSceneRequest?
    @ObservationIgnored private var importedLoadGeneration = UUID()
    @ObservationIgnored private var assetDetails = ImportedAssetDetailRegistry()
    @ObservationIgnored private var nativePreparationTask: Task<Void, any Error>?
    @ObservationIgnored private var nativePreparationID: UUID?
    @ObservationIgnored private let illustrationSession = IllustrationSession()
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
        responseTimeout = .seconds(60)
        encoder = JSONEncoder()
        decoder = JSONDecoder()
    }

    public init(
        initialState: SceneState,
        transport: any SceneTransport = SceneWebSocketClient(),
        responseTimeout: Duration = .seconds(60)
    ) {
        acceptedScene = initialState
        renderer = SceneRenderer(initialState: initialState)
        self.transport = transport
        self.responseTimeout = responseTimeout
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
        illustrationSession.retire()
        illustrationEnabled = false
        cancelActiveRequest(reason: "The scene connection was replaced.")
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
        let connectingSessionID = sessionID
        DiagnosticsLog.shared.record("connect.requested", component: "scene.controller", correlationID: connectingSessionID, fields: ["url_host": socketURL.host ?? "unknown"])
        transport.connect(
            to: socketURL,
            onMessage: { [weak self] data in
                guard let self, self.sessionID == connectingSessionID else { return }
                await self.receive(data)
            },
            onStateChange: { [weak self] state in
                guard let self else { return }
                guard self.sessionID == connectingSessionID else { return }
                switch state {
                case .disconnected:
                    self.connectionState = .disconnected
                    self.illustrationSession.retire()
                    self.illustrationEnabled = false
                    self.cancelActiveRequest(reason: "The scene connection closed.")
                case .connecting:
                    if self.connectionState != .connected {
                        self.connectionState = .connecting
                    }
                case .connected:
                    guard self.sessionID == connectingSessionID else { return }
                    Task { [weak self] in
                        await self?.beginHandshake(sessionID: connectingSessionID)
                    }
                case let .failed(message):
                    self.connectionState = .failed(message)
                    self.illustrationSession.retire()
                    self.illustrationEnabled = false
                    self.lastError = message
                    self.activity = nil
                    self.failActiveRequest(message)
                    DiagnosticsLog.shared.record("connect.failed", component: "scene.controller", level: .error, correlationID: connectingSessionID, fields: ["error": message])
                }
            }
        )
        connectionDeadlineTask?.cancel()
        connectionDeadlineTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.sessionID == connectingSessionID,
                  self.connectionState == .connecting else { return }
            self.transport.disconnect()
            self.connectionState = .failed("The session server did not respond. Check its address and availability, then retry.")
            self.report("The session server did not respond. Check its address and availability, then retry.")
            DiagnosticsLog.shared.record("connect.timeout", component: "scene.controller", level: .error, correlationID: connectingSessionID)
        }
    }

    public func disconnect() {
        illustrationSession.retire()
        illustrationEnabled = false
        nativePreparationTask?.cancel()
        cancelActiveRequest(reason: "The scene connection was closed.")
        transport.disconnect()
        connectionDeadlineTask?.cancel()
        responseDeadlineTask?.cancel()
        connectionState = .disconnected
        activity = nil
    }

    @discardableResult
    public func request(text: String, selection: SceneSelection? = nil, requestID: String? = nil) -> Bool {
        beginRequest(text: text, selection: selection, requestID: requestID, continuation: nil)
    }

    public func execute(
        text: String,
        selection: SceneSelection? = nil,
        requestID: String? = nil
    ) async -> SceneExecutionResult {
        let resolvedRequestID = requestID ?? "request_\(UUID().uuidString.lowercased())"
        let executionToken = UUID()
        let controllerReference = SceneControllerReference(self)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume(returning: executionResult(
                        requestID: resolvedRequestID,
                        status: .cancelled,
                        intentEpoch: acceptedScene.intentEpoch,
                        error: "The scene request was cancelled."
                    ))
                    return
                }
                _ = beginRequest(
                    text: text,
                    selection: selection,
                    requestID: resolvedRequestID,
                    continuation: continuation,
                    executionToken: executionToken
                )
            }
        } onCancel: {
            Task { @MainActor in
                controllerReference.value?.cancelExecution(requestID: resolvedRequestID, executionToken: executionToken)
            }
        }
    }

    private func beginRequest(
        text: String,
        selection: SceneSelection?,
        requestID: String?,
        continuation: CheckedContinuation<SceneExecutionResult, Never>?,
        executionToken: UUID? = nil
    ) -> Bool {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedRequestID = requestID ?? "request_\(UUID().uuidString.lowercased())"
        guard !text.isEmpty else {
            continuation?.resume(returning: executionResult(
                requestID: resolvedRequestID,
                status: .failed,
                intentEpoch: acceptedScene.intentEpoch,
                error: "Enter a scene request before sending."
            ))
            return false
        }
        guard connectionState == .connected, transport.state == .connected else {
            let message = "Connect to the scene backend before sending a request."
            report(message)
            continuation?.resume(returning: executionResult(
                requestID: resolvedRequestID,
                status: .failed,
                intentEpoch: acceptedScene.intentEpoch,
                error: message
            ))
            DiagnosticsLog.shared.record("request.rejected_offline", component: "scene.controller", level: .warning, correlationID: resolvedRequestID)
            return false
        }
        cancelActiveRequest(reason: "The scene request was superseded by a newer request.")
        let validNodeIDs = (selection?.nodeIDs ?? []).filter { requestedID in
            acceptedScene.document.nodes.contains { $0.nodeId == requestedID }
        }
        let epoch = acceptedScene.advanceIntentEpoch()
        illustrationSession.register(requestID: resolvedRequestID, scene: acceptedScene)
        installedRequestIDs.removeAll(keepingCapacity: true)
        let fenceRequestID = "supersede_\(UUID().uuidString.lowercased())"
        let request = UserRequest(
            requestId: resolvedRequestID,
            text: text,
            selection: validNodeIDs.isEmpty ? nil : .init(nodeIds: validNodeIDs)
        )
        let snapshot = makeSnapshot(prioritizing: validNodeIDs)
        lastExplanation = nil
        lastError = nil
        activity = "sending"
        activeRequest = ActiveSceneRequest(
            requestID: request.requestId,
            intentEpoch: epoch,
            continuation: continuation,
            executionToken: executionToken
        )
        responseDeadlineTask?.cancel()
        let requestSessionID = sessionID
        DiagnosticsLog.shared.record("request.started", component: "scene.controller", correlationID: request.requestId, fields: ["intent_epoch": "\(epoch)", "selection_count": "\(validNodeIDs.count)"])
        requestSendTask = Task { [weak self] in
            guard let self else { return }
            do {
                guard self.canSend(requestID: request.requestId, intentEpoch: epoch, sessionID: requestSessionID) else { return }
                try await self.transport.send(
                    IntentControl(
                        type: "user.stop",
                        requestId: fenceRequestID,
                        sceneId: self.acceptedScene.sceneId,
                        intentEpoch: epoch
                    ),
                    using: self.encoder
                )
                guard self.canSend(requestID: request.requestId, intentEpoch: epoch, sessionID: requestSessionID) else { return }
                try await self.transport.send(snapshot, using: self.encoder)
                guard self.canSend(requestID: request.requestId, intentEpoch: epoch, sessionID: requestSessionID) else { return }
                try await self.transport.send(request, using: self.encoder)
                guard self.isActive(requestID: request.requestId, intentEpoch: epoch) else { return }
                self.activity = "awaiting response"
                self.startResponseDeadline(requestID: request.requestId, intentEpoch: epoch)
                DiagnosticsLog.shared.record("request.sent", component: "scene.controller", correlationID: request.requestId, fields: ["intent_epoch": "\(epoch)"])
            } catch {
                self.failActiveRequest(error.localizedDescription, requestID: request.requestId, intentEpoch: epoch)
            }
        }
        return true
    }

    @discardableResult
    public func request(text: String, speechLock: PointingSpeechLock?, requestID: String? = nil) -> Bool {
        let lockedSelection: SceneSelection?
        if let speechLock,
           speechLock.selection.sceneID == acceptedScene.sceneId,
           acceptedScene.document.nodes.contains(where: { $0.nodeId == speechLock.selection.nodeID })
        {
            lockedSelection = SceneSelection(nodeIDs: [speechLock.selection.nodeID])
        } else {
            lockedSelection = nil
        }
        return request(text: text, selection: lockedSelection, requestID: requestID)
    }

    public func stop() {
        cancelIllustration()
        stopSceneRequest()
    }

    private func stopSceneRequest() {
        nativePreparationTask?.cancel()
        cancelActiveRequest(reason: "The scene request was stopped.")
        let epoch = acceptedScene.advanceIntentEpoch()
        installedRequestIDs.removeAll(keepingCapacity: true)
        responseDeadlineTask?.cancel()
        let requestID = "stop_\(UUID().uuidString.lowercased())"
        let snapshot = makeSnapshot()
        activity = nil
        guard connectionState == .connected, transport.state == .connected else { return }
        let requestSessionID = sessionID
        Task { [weak self] in
            guard let self else { return }
            do {
                guard self.sessionID == requestSessionID, self.acceptedScene.intentEpoch == epoch else { return }
                try await self.transport.send(
                    IntentControl(type: "user.stop", requestId: requestID, sceneId: self.acceptedScene.sceneId, intentEpoch: epoch),
                    using: self.encoder
                )
                guard self.sessionID == requestSessionID, self.acceptedScene.intentEpoch == epoch else { return }
                try await self.transport.send(snapshot, using: self.encoder)
            } catch {
                self.report(error)
            }
        }
    }

    public func cancelIllustration() {
        guard let jobID = illustrationSession.cancel() else { return }
        sendIllustrationControl(type: "illustration.cancel", jobID: jobID)
    }

    public func retryIllustration() {
        guard illustrationEnabled, connectionState == .connected,
              let serverURL = lastConnectedURL else { return }
        guard let jobID = illustrationSession.retry(scene: acceptedScene,
            serverURL: serverURL, authToken: sessionAuthToken) else { return }
        sendIllustrationControl(type: "illustration.retry", jobID: jobID)
    }

    public func dismissIllustration() {
        illustrationSession.dismiss()
    }

    private func sendIllustrationControl(type: String, jobID: String) {
        guard connectionState == .connected, transport.state == .connected else { return }
        let sendingSessionID = sessionID
        Task { [weak self] in
            guard let self, self.sessionID == sendingSessionID else { return }
            if type == "illustration.retry" {
                guard self.illustration?.jobID == jobID, self.illustration?.phase == .retrying else { return }
            }
            do {
                try await self.transport.send(IllustrationControl(type: type, jobId: jobID), using: self.encoder)
            } catch {
                guard self.sessionID == sendingSessionID else { return }
                self.illustrationSession.controlFailed(jobID: jobID)
            }
        }
    }

    public func undo() {
        cancelActiveRequest(reason: "The scene request was cancelled by undo.")
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
            illustrationSession.retire()
            renderer.installPreparedScene(acceptedScene.document, prepared: prepared)
            renderer.setImportedAssetPins(acceptedScene.retainedImportedAssetIDs)
            lastExplanation = nil
            if let selected = selection?.primaryNodeID,
               !acceptedScene.document.nodes.contains(where: { $0.nodeId == selected })
            {
                setSelection(nil)
            }
        }
        lastReceipt = .scene(receipt)
        let snapshot = makeSnapshot()

        guard connectionState == .connected, transport.state == .connected else { return }
        let requestSessionID = sessionID
        Task { [weak self] in
            guard let self else { return }
            do {
                guard self.sessionID == requestSessionID, self.acceptedScene.intentEpoch == committedEpoch else { return }
                try await self.transport.send(
                    IntentControl(type: "user.undo", requestId: requestID, sceneId: self.acceptedScene.sceneId, intentEpoch: committedEpoch),
                    using: self.encoder
                )
                guard self.sessionID == requestSessionID, self.acceptedScene.intentEpoch == committedEpoch else { return }
                try await self.transport.send(receipt, using: self.encoder)
                guard self.sessionID == requestSessionID, self.acceptedScene.intentEpoch == committedEpoch else { return }
                try await self.transport.send(snapshot, using: self.encoder)
            } catch {
                self.report(error)
            }
        }
    }

    public func loadScene(_ state: SceneState) throws {
        importedLoadGeneration = UUID()
        cancelActiveRequest(reason: "The scene request was cancelled because another scene was loaded.")
        let reconnectURL = connectionState == .disconnected ? nil : lastConnectedURL
        let prepared = try renderer.prepareScene(state.document)
        renderer.installPreparedScene(state.document, prepared: prepared)
        illustrationSession.retire()
        acceptedScene = state
        renderer.setImportedAssetPins(state.retainedImportedAssetIDs)
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

    /// Makes the next authored level discoverable without decoding its meshes.
    /// Resources are immutable and host-approved; model input contains no URLs.
    public func registerAssetDetails(_ templates: [ImportedAssetDetailTemplate],
                                     resources: [ImportedAssetDescriptor], cacheDirectory: URL? = nil) throws {
        try assetDetails.register(templates, resources: resources, cacheDirectory: cacheDirectory)
    }

    public var availableAssetDetails: [AvailableAssetDetail] {
        assetDetails.available(in: acceptedScene.document)
    }

    /// Loads a host-approved asset lazily, then installs through the same scene authority as procedural edits.
    @discardableResult
    public func loadImportedAsset(
        _ descriptor: ImportedAssetDescriptor,
        rootNodeID: String = "asset.root",
        scale: Double = 1,
        cacheDirectory: URL? = nil,
        progress: @escaping @MainActor (ImportedAssetLoadPhase) -> Void = { _ in }
    ) async throws -> ImportedAssetLoadReport {
        stop()
        var preparedAssetID: String?
        defer {
            if let preparedAssetID { renderer.finishImportedAssetPreparation(assetID: preparedAssetID) }
        }
        let generation = UUID()
        importedLoadGeneration = generation
        let startingSceneID = acceptedScene.sceneId
        let startingRevision = acceptedScene.revision
        let startingEpoch = acceptedScene.intentEpoch
        let (document, preparedReport) = try await renderer.prepareImportedAsset(
            descriptor, rootNodeID: rootNodeID, scale: scale, cacheDirectory: cacheDirectory,
            progress: { [weak self] phase in
                guard let self, self.importedLoadGeneration == generation,
                      self.acceptedScene.sceneId == startingSceneID,
                      self.acceptedScene.revision == startingRevision,
                      self.acceptedScene.intentEpoch == startingEpoch else { return }
                progress(phase)
            })
        preparedAssetID = descriptor.assetID
        try Task.checkCancellation()
        guard importedLoadGeneration == generation,
              acceptedScene.sceneId == startingSceneID,
              acceptedScene.revision == startingRevision,
              acceptedScene.intentEpoch == startingEpoch else {
            throw ImportedAssetError.superseded
        }
        progress(.installing)
        guard importedLoadGeneration == generation,
              acceptedScene.sceneId == startingSceneID,
              acceptedScene.revision == startingRevision,
              acceptedScene.intentEpoch == startingEpoch else { throw ImportedAssetError.superseded }
        let installStart = ContinuousClock.now
        try loadScene(document)
        var report = preparedReport
        let elapsed = installStart.duration(to: .now)
        report.installDurationSeconds = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
        if let root = renderer.entity(for: rootNodeID) {
            let bounds = root.visualBounds(relativeTo: nil)
            report.boundsMinimum = Vec3(Double(bounds.min.x), Double(bounds.min.y), Double(bounds.min.z))
            report.boundsMaximum = Vec3(Double(bounds.max.x), Double(bounds.max.y), Double(bounds.max.z))
        }
        DiagnosticsLog.shared.record("asset.installed", component: "scene.controller", fields: [
            "asset_id": descriptor.assetID,
            "nodes": "\(report.nodeIDs.count)",
            "file_cache": "\(report.usedFileCache)",
            "entity_cache": "\(report.usedEntityCache)",
            "load_seconds": "\(report.loadDurationSeconds)",
            "install_seconds": "\(report.installDurationSeconds)",
            "native_models": "\(report.importedModelCount)",
            "expanded_triangles": "\(report.expandedTriangleCount)",
        ])
        return report
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
            DiagnosticsLog.shared.record("hand.detection_failed", component: "scene.pointing", level: .warning,
                                         fields: ["error": reason])
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
        activity = nil
        DiagnosticsLog.shared.record("operation.failed", component: "scene.controller", level: .error, fields: ["error": message])
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
                illustrationEnabled = accepted.illustrationEnabled == true
                connectionDeadlineTask?.cancel()
                DiagnosticsLog.shared.record("handshake.accepted", component: "scene.controller", correlationID: sessionID)
            case "illustration.state":
                // Image ingress must never fail or satisfy a scene receipt.
                guard illustrationEnabled, connectionState == .connected,
                      let serverURL = lastConnectedURL else { return }
                do {
                    let event = try decoder.decode(IllustrationStateEvent.self, from: data)
                    illustrationSession.receive(event, scene: acceptedScene,
                        serverURL: serverURL, authToken: sessionAuthToken)
                } catch {
                    DiagnosticsLog.shared.record("illustration.invalid_state", component: "scene.illustration", level: .warning)
                }
            case "generation.begin", "generation.batch", "generation.finish", "scene.patch":
                let message = try wireDecoder.decodeMessage(from: data)
                let receivedSessionID = sessionID
                let result = await applyIncoming(message)
                guard sessionID == receivedSessionID else { return }
                DiagnosticsLog.shared.record("scene.reduced", component: "scene.controller", correlationID: result.receipt.sceneIdentity.requestID, fields: ["document_changed": "\(result.documentChanged)"])
                lastReceipt = result.receipt
                if case let .scene(receipt) = result.receipt, receipt.status == .installed {
                    installedRequestIDs.insert(receipt.requestId)
                }
                if let rejection = result.receipt.rejection,
                   isActive(requestID: result.receipt.sceneIdentity.requestID, intentEpoch: acceptedScene.intentEpoch)
                {
                    failActiveRequest("\(rejection.code): \(rejection.message)")
                }
                let snapshot = result.documentChanged ? makeSnapshot() : nil
                try await transport.send(result.receipt, using: encoder)
                if let snapshot {
                    try await transport.send(snapshot, using: encoder)
                }
            case "session.explanation":
                let explanation = try decoder.decode(SessionExplanation.self, from: data)
                if let activeRequest, explanation.requestId != activeRequest.requestID {
                    DiagnosticsLog.shared.record("explanation.stale", component: "scene.controller", level: .warning, correlationID: explanation.requestId)
                    return
                }
                guard explanation.intentEpoch == acceptedScene.intentEpoch,
                      explanation.proposalRequestIds.allSatisfy(installedRequestIDs.contains)
                else {
                    throw SessionRuntimeError.unverifiedExplanation
                }
                lastExplanation = explanation.text
                activity = nil
                if isActive(requestID: explanation.requestId, intentEpoch: explanation.intentEpoch) {
                    finishActiveRequest(
                        status: .completed,
                        proposalRequestIDs: explanation.proposalRequestIds,
                        explanation: explanation.text
                    )
                }
                DiagnosticsLog.shared.record("explanation.accepted", component: "scene.controller", correlationID: explanation.requestId, fields: ["proposal_count": "\(explanation.proposalRequestIds.count)"])
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
                guard isActive(requestID: progress.requestId, intentEpoch: progress.intentEpoch) else { return }
                activity = progress.status
                DiagnosticsLog.shared.record("progress.received", component: "scene.controller", correlationID: progress.requestId, fields: ["status": progress.status, "intent_epoch": "\(progress.intentEpoch)"])
            case "session.model_text":
                // Model deltas are intentionally not user-visible evidence of an installed scene.
                DiagnosticsLog.shared.record("model_text.received", component: "scene.controller", correlationID: activeRequest?.requestID, fields: ["bytes": "\(data.count)"])
                break
            case "session.error":
                let serviceError = try decoder.decode(SessionErrorMessage.self, from: data)
                if serviceError.code.hasPrefix("illustration_"), serviceError.requestId?.isEmpty != false {
                    illustrationSession.controlRejected(serviceError.message)
                    return
                }
                if let requestID = serviceError.requestId,
                   requestID != activeRequest?.requestID {
                    DiagnosticsLog.shared.record("service.error_stale", component: "scene.controller", level: .warning, correlationID: requestID, fields: ["code": serviceError.code])
                    return
                }
                lastError = "\(serviceError.code): \(serviceError.message)"
                activity = nil
                failActiveRequest(lastError!)
                DiagnosticsLog.shared.record("service.error", component: "scene.controller", level: .error, correlationID: serviceError.requestId, fields: ["code": serviceError.code])
            default:
                throw SessionRuntimeError.unsupportedMessage(header.type)
            }
        } catch {
            report(error)
            failActiveRequest(error.localizedDescription)
        }
    }

    private func applyIncoming(_ message: ClientMessage) async -> IncomingResult {
        let startingSceneID = acceptedScene.sceneId
        let startingSessionID = sessionID
        let startingExecutionToken = activeRequest?.executionToken
        let startingRevision = acceptedScene.revision
        let startingEpoch = acceptedScene.intentEpoch
        let startingDocument = acceptedScene.document
        var candidate = acceptedScene
        let previewReceipt = candidate.apply(message)
        DiagnosticsLog.shared.record("native.prepare_started", component: "scene.controller", correlationID: message.sceneIdentity.requestID, fields: ["revision": "\(startingRevision)", "intent_epoch": "\(startingEpoch)"])

        let prepared: PreparedScene?
        var preparedAssetIDs: [String] = []
        defer {
            for assetID in preparedAssetIDs { renderer.finishImportedAssetPreparation(assetID: assetID) }
        }
        if previewReceipt.installedScene, candidate.document != startingDocument {
            do {
                let preparationID = UUID()
                let preparationTask = Task { @MainActor in
                    try await self.renderer.prepareImportedResources(for: candidate.document,
                        approved: assetDetails.resources, cacheDirectory: assetDetails.cacheDirectory,
                        didPrepare: { preparedAssetIDs.append($0) }, progress: { [weak self] phase in
                            guard let self, self.acceptedScene.sceneId == startingSceneID,
                                  self.acceptedScene.revision == startingRevision,
                                  self.acceptedScene.intentEpoch == startingEpoch,
                                  self.sessionID == startingSessionID,
                                  startingExecutionToken == nil || self.activeRequest?.executionToken == startingExecutionToken else { return }
                            self.activity = phase == .downloading ? "downloading_asset" : "loading_asset"
                            DiagnosticsLog.shared.record("asset.detail_preparing", component: "scene.controller",
                                correlationID: message.sceneIdentity.requestID, fields: ["phase": phase.rawValue])
                        })
                }
                nativePreparationTask?.cancel()
                nativePreparationTask = preparationTask
                nativePreparationID = preparationID
                defer {
                    if nativePreparationID == preparationID {
                        nativePreparationTask = nil
                        nativePreparationID = nil
                    }
                }
                try await preparationTask.value
                try Task.checkCancellation()
                prepared = try renderer.prepareScene(candidate.document)
                DiagnosticsLog.shared.record("native.prepare_finished", component: "scene.controller", correlationID: message.sceneIdentity.requestID, fields: ["node_count": "\(candidate.document.nodes.count)"])
            } catch {
                if error is CancellationError || acceptedScene.sceneId != startingSceneID
                    || sessionID != startingSessionID || acceptedScene.revision != startingRevision
                    || acceptedScene.intentEpoch != startingEpoch
                    || (startingExecutionToken != nil && activeRequest?.executionToken != startingExecutionToken) {
                    DiagnosticsLog.shared.record("native.prepare_cancelled", component: "scene.controller",
                        correlationID: message.sceneIdentity.requestID)
                    return IncomingResult(receipt: .scene(staleCommitRejection(for: message)), documentChanged: false)
                }
                DiagnosticsLog.shared.record("native.prepare_failed", component: "scene.controller", level: .error, correlationID: message.sceneIdentity.requestID, fields: ["error": error.localizedDescription])
                return IncomingResult(
                    receipt: .scene(renderRejection(from: previewReceipt, error: error)),
                    documentChanged: false
                )
            }
        } else {
            prepared = nil
        }

        guard acceptedScene.sceneId == startingSceneID, sessionID == startingSessionID,
              acceptedScene.revision == startingRevision, acceptedScene.intentEpoch == startingEpoch,
              startingExecutionToken == nil || activeRequest?.executionToken == startingExecutionToken else {
            return IncomingResult(
                receipt: .scene(staleCommitRejection(for: message)),
                documentChanged: false
            )
        }

        let receipt = acceptedScene.apply(message)
        if acceptedScene.revision != startingRevision || acceptedScene.document != startingDocument {
            illustrationSession.retire()
        }
        let documentChanged = receipt.installedScene && acceptedScene.document != startingDocument
        if documentChanged, let prepared {
            renderer.installPreparedScene(acceptedScene.document, prepared: prepared)
            renderer.setImportedAssetPins(acceptedScene.retainedImportedAssetIDs)
            lastExplanation = nil
            DiagnosticsLog.shared.record("native.installed", component: "scene.controller", correlationID: receipt.sceneIdentity.requestID, fields: ["revision": "\(acceptedScene.revision)", "node_count": "\(acceptedScene.document.nodes.count)"])
        }
        DiagnosticsLog.shared.record("receipt.created", component: "scene.controller", correlationID: receipt.sceneIdentity.requestID, fields: ["installed": "\(receipt.installedScene)", "revision": "\(acceptedScene.revision)"])
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

    private func beginHandshake(sessionID: String) async {
        guard self.sessionID == sessionID, connectionState == .connecting else { return }
        do {
            try await sendSessionHello()
            guard !Task.isCancelled, self.sessionID == sessionID,
                  connectionState == .connecting || connectionState == .connected,
                  transport.state == .connected else { return }
            try await sendSnapshot()
            DiagnosticsLog.shared.record("handshake.sent", component: "scene.controller", correlationID: sessionID)
        } catch {
            guard self.sessionID == sessionID else { return }
            connectionState = .failed(error.localizedDescription)
            report(error)
        }
    }

    private func startResponseDeadline(requestID: String, intentEpoch: UInt64) {
        responseDeadlineTask?.cancel()
        responseDeadlineTask = Task { [weak self, responseTimeout] in
            try? await Task.sleep(for: responseTimeout)
            guard !Task.isCancelled else { return }
            self?.timeoutActiveRequest(
                "The scene backend did not respond in time. Check the connection and try again.",
                requestID: requestID,
                intentEpoch: intentEpoch
            )
        }
    }

    private func isActive(requestID: String, intentEpoch: UInt64) -> Bool {
        activeRequest?.requestID == requestID && activeRequest?.intentEpoch == intentEpoch
    }

    private func canSend(requestID: String, intentEpoch: UInt64, sessionID: String) -> Bool {
        !Task.isCancelled && self.sessionID == sessionID &&
            connectionState == .connected && transport.state == .connected &&
            isActive(requestID: requestID, intentEpoch: intentEpoch)
    }

    private func timeoutActiveRequest(_ message: String, requestID: String, intentEpoch: UInt64) {
        guard isActive(requestID: requestID, intentEpoch: intentEpoch) else { return }
        requestSendTask?.cancel()
        requestSendTask = nil
        let fenceEpoch = acceptedScene.advanceIntentEpoch()
        installedRequestIDs.removeAll(keepingCapacity: true)
        let snapshot = makeSnapshot()
        let timeoutSessionID = sessionID
        if connectionState == .connected, transport.state == .connected {
            Task { [weak self] in
                guard let self, self.sessionID == timeoutSessionID,
                      self.acceptedScene.intentEpoch == fenceEpoch else { return }
                try? await self.transport.send(
                    IntentControl(
                        type: "user.stop",
                        requestId: "timeout_\(requestID)",
                        sceneId: self.acceptedScene.sceneId,
                        intentEpoch: fenceEpoch
                    ),
                    using: self.encoder
                )
                guard self.sessionID == timeoutSessionID,
                      self.acceptedScene.intentEpoch == fenceEpoch else { return }
                try? await self.transport.send(snapshot, using: self.encoder)
            }
        }
        failActiveRequest(message, requestID: requestID, intentEpoch: intentEpoch)
    }

    private func failActiveRequest(_ message: String, requestID: String, intentEpoch: UInt64) {
        guard isActive(requestID: requestID, intentEpoch: intentEpoch) else { return }
        lastError = message
        finishActiveRequest(status: .failed, error: message)
        DiagnosticsLog.shared.record("request.failed", component: "scene.controller", level: .error, correlationID: requestID, fields: ["intent_epoch": "\(intentEpoch)", "error": message])
    }

    private func failActiveRequest(_ message: String) {
        guard activeRequest != nil else { return }
        lastError = message
        finishActiveRequest(status: .failed, error: message)
    }

    private func cancelActiveRequest(reason: String) {
        nativePreparationTask?.cancel()
        guard activeRequest != nil else { return }
        finishActiveRequest(status: .cancelled, error: reason)
    }

    private func cancelExecution(requestID: String, executionToken: UUID) {
        guard activeRequest?.requestID == requestID,
              activeRequest?.executionToken == executionToken else { return }
        cancelActiveRequest(reason: "The scene request was cancelled.")
        stopSceneRequest()
    }

    private func finishActiveRequest(
        status: SceneExecutionStatus,
        proposalRequestIDs: [String]? = nil,
        explanation: String? = nil,
        error: String? = nil
    ) {
        guard let activeRequest else { return }
        if status != .completed { nativePreparationTask?.cancel() }
        requestSendTask?.cancel()
        requestSendTask = nil
        responseDeadlineTask?.cancel()
        responseDeadlineTask = nil
        self.activeRequest = nil
        activity = nil
        let result = executionResult(
            requestID: activeRequest.requestID,
            status: status,
            intentEpoch: activeRequest.intentEpoch,
            proposalRequestIDs: proposalRequestIDs ?? installedRequestIDs.sorted(),
            explanation: explanation,
            error: error
        )
        activeRequest.continuation?.resume(returning: result)
    }

    private func executionResult(
        requestID: String,
        status: SceneExecutionStatus,
        intentEpoch: UInt64,
        proposalRequestIDs: [String] = [],
        explanation: String? = nil,
        error: String? = nil
    ) -> SceneExecutionResult {
        SceneExecutionResult(
            requestID: requestID,
            status: status,
            sceneID: acceptedScene.sceneId,
            revision: acceptedScene.revision,
            intentEpoch: intentEpoch,
            proposalRequestIDs: proposalRequestIDs,
            explanation: explanation,
            error: error
        )
    }

    private func sendSnapshot() async throws {
        try await transport.send(makeSnapshot(), using: encoder)
    }

    private func makeSnapshot(prioritizing requestedNodeIDs: [String]? = nil) -> PhoneSnapshot {
        let details = availableAssetDetails
        let bounds = renderer.nodeLocalBounds(prioritizing: Self.boundsPriorityNodeIDs(
            in: acceptedScene.document, selectionIDs: requestedNodeIDs ?? selection?.nodeIDs ?? []), maximumCount: 128)
        return PhoneSnapshot(
            sceneId: acceptedScene.sceneId,
            revision: acceptedScene.revision,
            intentEpoch: acceptedScene.intentEpoch,
            document: acceptedScene.document,
            availableAssetDetails: details.isEmpty ? nil : details,
            nodeLocalBounds: bounds.isEmpty ? nil : bounds
        )
    }

    /// Keep the selected structure and its hierarchy ahead of unrelated bounds
    /// when a large assembly exceeds the measured-context budget.
    static func boundsPriorityNodeIDs(in document: SceneDocument, selectionIDs: [String],
                                     maximumCount: Int = 128) -> [String] {
        let limit = min(128, max(0, maximumCount))
        guard limit > 0, !selectionIDs.isEmpty else { return [] }
        let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.nodeId, $0) })
        var children: [String: [String]] = [:]
        for node in document.nodes {
            if let parentID = node.parentId { children[parentID, default: []].append(node.nodeId) }
        }
        let selected = selectionIDs.filter { nodes[$0] != nil }
        var result: [String] = []
        var included = Set<String>()
        func include(_ nodeID: String) {
            if result.count < limit, included.insert(nodeID).inserted { result.append(nodeID) }
        }
        for nodeID in selected { include(nodeID) }
        for nodeID in selected {
            var parentID = nodes[nodeID]?.parentId
            var ancestors = Set<String>()
            while let current = parentID, ancestors.insert(current).inserted, result.count < limit {
                guard let parent = nodes[current] else { break }
                include(current)
                parentID = parent.parentId
            }
        }
        var queue = selected
        var visited = Set<String>()
        var cursor = 0
        while cursor < queue.count, result.count < limit {
            let current = queue[cursor]
            cursor += 1
            guard visited.insert(current).inserted else { continue }
            for childID in children[current] ?? [] {
                include(childID)
                if result.count < limit { queue.append(childID) }
            }
        }
        return result
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

private struct ActiveSceneRequest {
    var requestID: String
    var intentEpoch: UInt64
    var continuation: CheckedContinuation<SceneExecutionResult, Never>?
    var executionToken: UUID?
}

private final class SceneControllerReference: @unchecked Sendable {
    weak var value: SceneController?

    init(_ value: SceneController) {
        self.value = value
    }
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

    var rejection: Rejection? {
        switch self {
        case let .scene(receipt): receipt.rejection
        case let .generation(receipt): receipt.rejection
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
