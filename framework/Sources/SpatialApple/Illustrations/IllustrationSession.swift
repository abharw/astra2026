import Foundation
import Observation
import SpatialCore

public enum IllustrationPhase: Sendable, Equatable {
    case generating
    case downloading
    case retrying
    case ready
    case failed(String)
    case cancelled
}

public struct IllustrationPresentation: Sendable, Equatable {
    public var jobID: String
    public var requestID: String
    public var componentNames: [String]
    public var phase: IllustrationPhase
    public var artifact: IllustrationArtifact?
    public var fileURL: URL?
    public var canRetry = true
}

struct IllustrationStateEvent: Decodable {
    enum Status: String, Decodable { case generating, ready, failed, cancelled, stale }
    var jobId: String
    var requestId: String
    var sceneId: String
    var revision: UInt64
    var intentEpoch: UInt64
    var componentNodeIds: [String]
    var status: Status
    var artifact: IllustrationArtifact?
    var error: String?
    var cacheHit: Bool?
}

struct IllustrationControl: Encodable {
    var type: String
    var jobId: String
}

/// An image has its own lifetime. Conversation completion and intent-epoch
/// changes are deliberately absent from this state machine's currency checks.
@MainActor
@Observable
final class IllustrationSession {
    private(set) var presentation: IllustrationPresentation?
    @ObservationIgnored private let loader: IllustrationArtifactLoader
    @ObservationIgnored private var requests: [String: RequestContext] = [:]
    @ObservationIgnored private var requestOrder: [String] = []
    @ObservationIgnored private var consumedRequests = Set<String>()
    @ObservationIgnored private var currentContext: RequestContext?
    @ObservationIgnored private var currentEvent: IllustrationStateEvent?
    @ObservationIgnored private var latestImageEpoch: UInt64 = 0
    @ObservationIgnored private var retiredJobs = Set<String>()
    @ObservationIgnored private var retiredJobOrder: [String] = []
    @ObservationIgnored private var retryRequestID: String?
    @ObservationIgnored private var transferTask: Task<Void, Never>?
    @ObservationIgnored private var transferIdentity = UUID()

    private struct RequestContext {
        var sceneID: String
        var revision: UInt64
        var intentEpoch: UInt64
        var document: SceneDocument

        func matches(_ scene: SceneState) -> Bool {
            sceneID == scene.sceneId && revision == scene.revision && document == scene.document
        }
    }

    init(loader: IllustrationArtifactLoader = IllustrationArtifactLoader()) {
        self.loader = loader
    }

    func register(requestID: String, scene: SceneState) {
        requests[requestID] = RequestContext(sceneID: scene.sceneId, revision: scene.revision,
            intentEpoch: scene.intentEpoch, document: scene.document)
        requestOrder.removeAll { $0 == requestID }
        requestOrder.append(requestID)
        while requestOrder.count > 32 {
            let removed = requestOrder.removeFirst()
            requests.removeValue(forKey: removed)
            consumedRequests.remove(removed)
        }
    }

    func receive(_ event: IllustrationStateEvent, scene: SceneState, serverURL: URL, authToken: String?) {
        guard !event.jobId.isEmpty, event.jobId.utf8.count <= 256,
              !event.requestId.isEmpty, event.requestId.utf8.count <= 256,
              event.componentNodeIds.count <= 16,
              Set(event.componentNodeIds).count == event.componentNodeIds.count,
              event.componentNodeIds.allSatisfy({ id in scene.document.nodes.contains { $0.nodeId == id } }),
              event.sceneId == scene.sceneId, event.revision == scene.revision,
              !retiredJobs.contains(event.jobId) else { return }

        if event.jobId != presentation?.jobID {
            guard event.status == .generating || event.status == .ready,
                  let context = requests[event.requestId], context.matches(scene),
                  context.intentEpoch == event.intentEpoch,
                  event.intentEpoch >= latestImageEpoch,
                  !consumedRequests.contains(event.requestId) || retryRequestID == event.requestId else { return }
            if let oldJob = presentation?.jobID { retireJob(oldJob) }
            cancelTransfer()
            currentContext = context
            currentEvent = event
            consumedRequests.insert(event.requestId)
            latestImageEpoch = event.intentEpoch
            retryRequestID = nil
            presentation = IllustrationPresentation(jobID: event.jobId, requestID: event.requestId,
                componentNames: event.componentNodeIds.compactMap { id in
                    scene.document.nodes.first { $0.nodeId == id }?.semantic.name
                }, phase: .generating)
        }

        guard let currentContext, currentContext.matches(scene),
              currentEvent?.requestId == event.requestId,
              currentEvent?.componentNodeIds == event.componentNodeIds,
              currentEvent?.intentEpoch == event.intentEpoch else { return }
        if event.status == .stale {
            retire()
            return
        }
        // Terminal state can never be reopened by a duplicate or late event.
        guard presentation?.phase == .generating else { return }
        currentEvent = event
        switch event.status {
        case .generating:
            break
        case .ready:
            guard let artifact = event.artifact, artifact.sourceRevision >= 0,
                  UInt64(artifact.sourceRevision) == event.revision else {
                presentation?.phase = .failed("The illustration metadata does not match this scene.")
                presentation?.canRetry = false
                return
            }
            presentation?.artifact = artifact
            download(artifact, serverURL: serverURL, authToken: authToken)
        case .failed:
            presentation?.phase = .failed(String((event.error ?? "The illustration could not be generated.").prefix(500)))
        case .cancelled:
            presentation?.phase = .cancelled
        case .stale:
            retire()
        }
        DiagnosticsLog.shared.record("illustration.state", component: "scene.illustration",
            correlationID: event.jobId, fields: ["status": event.status.rawValue, "revision": String(event.revision)])
    }

    /// Also clears requests whose admission message has not arrived yet, so Stop
    /// cannot race a queued first generating event and resurrect that job.
    func cancel() -> String? {
        requests.removeAll()
        requestOrder.removeAll()
        consumedRequests.removeAll()
        retryRequestID = nil
        guard let presentation else { return nil }
        switch presentation.phase {
        case .generating, .downloading, .retrying:
            cancelTransfer()
            retireJob(presentation.jobID)
            self.presentation?.phase = .cancelled
            return presentation.jobID
        case .ready, .failed, .cancelled:
            return nil
        }
    }

    /// Returns the failed backend job to retry. A failed download reuses its
    /// verified artifact metadata and never sends another authoring request.
    func retry(scene: SceneState, serverURL: URL, authToken: String?) -> String? {
        guard let presentation, presentation.canRetry, let currentContext, currentContext.matches(scene) else { return nil }
        switch presentation.phase {
        case .failed, .cancelled: break
        default: return nil
        }
        if let artifact = presentation.artifact {
            download(artifact, serverURL: serverURL, authToken: authToken)
            return nil
        }
        requests[presentation.requestID] = currentContext
        retryRequestID = presentation.requestID
        retireJob(presentation.jobID)
        self.presentation?.phase = .retrying
        cancelTransfer()
        let identity = transferIdentity
        transferTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            guard !Task.isCancelled, let self, self.transferIdentity == identity,
                  self.presentation?.phase == .retrying else { return }
            self.retryRequestID = nil
            self.presentation?.phase = .failed("The illustration retry was not acknowledged. Please retry.")
        }
        return presentation.jobID
    }

    func controlFailed(jobID: String) {
        guard presentation?.jobID == jobID, presentation?.phase == .retrying else { return }
        cancelTransfer()
        retryRequestID = nil
        presentation?.phase = .failed("The illustration request could not be sent. Please retry.")
    }

    func controlRejected(_ message: String) {
        guard presentation?.phase == .retrying else { return }
        cancelTransfer()
        retryRequestID = nil
        presentation?.phase = .failed(String(message.prefix(500)))
    }

    func retire() {
        if let jobID = presentation?.jobID { retireJob(jobID) }
        cancelTransfer()
        presentation = nil
        currentContext = nil
        currentEvent = nil
        retryRequestID = nil
        requests.removeAll()
        requestOrder.removeAll()
        consumedRequests.removeAll()
        latestImageEpoch = 0
    }

    func dismiss() {
        guard let presentation else { return }
        retireJob(presentation.jobID)
        cancelTransfer()
        self.presentation = nil
        currentContext = nil
        currentEvent = nil
        retryRequestID = nil
    }

    private func download(_ artifact: IllustrationArtifact, serverURL: URL, authToken: String?) {
        cancelTransfer()
        presentation?.phase = .downloading
        let identity = transferIdentity
        let jobID = presentation?.jobID
        transferTask = Task { [weak self, loader] in
            do {
                let fileURL = try await loader.load(artifact, serverURL: serverURL, authToken: authToken)
                guard !Task.isCancelled, let self, self.transferIdentity == identity,
                      self.presentation?.jobID == jobID else { return }
                self.presentation?.fileURL = fileURL
                self.presentation?.phase = .ready
                self.transferTask = nil
                DiagnosticsLog.shared.record("illustration.ready", component: "scene.illustration",
                    correlationID: jobID, fields: ["bytes": String(artifact.byteCount), "sha256": artifact.sha256])
            } catch {
                guard !Task.isCancelled, let self, self.transferIdentity == identity,
                      self.presentation?.jobID == jobID else { return }
                self.presentation?.phase = .failed(error.localizedDescription)
                if error as? IllustrationArtifactError == .invalidMetadata {
                    self.presentation?.canRetry = false
                }
                self.transferTask = nil
                DiagnosticsLog.shared.record("illustration.download_failed", component: "scene.illustration",
                    level: .warning, correlationID: jobID)
            }
        }
    }

    private func cancelTransfer() {
        transferIdentity = UUID()
        transferTask?.cancel()
        transferTask = nil
    }

    private func retireJob(_ jobID: String) {
        guard retiredJobs.insert(jobID).inserted else { return }
        retiredJobOrder.append(jobID)
        if retiredJobOrder.count > 128 { retiredJobs.remove(retiredJobOrder.removeFirst()) }
    }
}
