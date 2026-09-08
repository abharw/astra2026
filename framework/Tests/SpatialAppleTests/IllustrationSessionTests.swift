import Foundation
import SpatialCore
@testable import SpatialApple
import Testing

@MainActor
private func imageState() throws -> SceneState {
    try SceneState(document: SceneDocument(documentId: "illustration-document"), sceneId: "illustration-scene")
}

private func imageEvent(job: String = "image-job", request: String = "image-request", epoch: UInt64 = 0,
                        status: IllustrationStateEvent.Status = .generating) -> IllustrationStateEvent {
    IllustrationStateEvent(jobId: job, requestId: request, sceneId: "illustration-scene", revision: 0,
        intentEpoch: epoch, componentNodeIds: [], status: status)
}

private let imageServer = URL(string: "https://example.com/session")!

@MainActor @Test func illustrationSurvivesOrdinaryConversationEpochChange() throws {
    let images = IllustrationSession()
    var scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    _ = scene.advanceIntentEpoch()
    images.register(requestID: "ordinary-followup", scene: scene)
    images.receive(imageEvent(status: .failed), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.jobID == "image-job")
    if case .failed = images.presentation?.phase {} else { Issue.record("The original image should remain current.") }
}

@MainActor @Test func explicitStopFencesAdmissionBeforeJobIDArrives() throws {
    let images = IllustrationSession()
    let scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    #expect(images.cancel() == nil)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation == nil)
}

@MainActor @Test func cancelledIllustrationCanBeExplicitlyRetriedWithoutSceneReplay() throws {
    let images = IllustrationSession()
    var scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.cancel() == "image-job")
    _ = scene.advanceIntentEpoch()
    #expect(images.retry(scene: scene, serverURL: imageServer, authToken: nil) == "image-job")
    #expect(images.presentation?.phase == .retrying)
    images.receive(imageEvent(job: "retried-job"), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.jobID == "retried-job")
    #expect(images.presentation?.phase == .generating)
    images.receive(imageEvent(status: .ready), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.jobID == "retried-job")
    #expect(images.presentation?.phase == .generating)
    images.retire()
}

@MainActor @Test func stoppedRetryCannotBeReopenedByLateNewIdentity() throws {
    let images = IllustrationSession()
    let scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    _ = images.cancel()
    _ = images.retry(scene: scene, serverURL: imageServer, authToken: nil)
    _ = images.cancel()
    images.receive(imageEvent(job: "late-retry"), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.phase == .cancelled)
    #expect(images.presentation?.jobID == "image-job")
}

@MainActor @Test func changedSceneAndUnknownComponentsRejectIllustrationAdmission() throws {
    let images = IllustrationSession()
    var scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    var invalid = imageEvent()
    invalid.componentNodeIds = ["missing"]
    images.receive(invalid, scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation == nil)
    scene = try SceneState(document: SceneDocument(documentId: "changed-document"), sceneId: scene.sceneId)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation == nil)
}

@MainActor @Test func oldAndUnrequestedJobsCannotReplaceCurrentIllustration() throws {
    let images = IllustrationSession()
    var scene = try imageState()
    images.register(requestID: "old-request", scene: scene)
    _ = scene.advanceIntentEpoch()
    images.register(requestID: "new-request", scene: scene)
    images.receive(imageEvent(job: "new-job", request: "new-request", epoch: 1),
        scene: scene, serverURL: imageServer, authToken: nil)
    images.receive(imageEvent(request: "old-request"), scene: scene, serverURL: imageServer, authToken: nil)
    images.receive(imageEvent(job: "unrequested", request: "unknown", epoch: 1),
        scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.jobID == "new-job")
    images.retire()
    images.receive(imageEvent(job: "new-job", request: "new-request", epoch: 1),
        scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation == nil)
}

@MainActor
private final class IllustrationTestTransport: SceneTransport {
    var state: SceneWebSocketClient.State = .disconnected
    var sent: [[String: Any]] = []
    var receiver: (@MainActor (Data) async -> Void)?
    func connect(to url: URL, onMessage: @escaping @MainActor (Data) async -> Void,
                 onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void) {
        receiver = onMessage
        state = .connected
        onStateChange(.connected)
    }
    func disconnect() { state = .disconnected }
    func send(_ data: Data) async throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        sent.append(object)
        if object["type"] as? String == "session.hello" {
            #expect((object["capabilities"] as? [String])?.contains("illustration.v1") == true)
            let sessionID = try #require(object["sessionId"] as? String)
            await receiver?(try JSONSerialization.data(withJSONObject: [
                "type": "session.accepted", "protocolVersion": 1, "sessionId": sessionID,
                "sceneSchemaVersion": 1, "geometrySemanticsVersion": 1, "illustrationEnabled": true,
            ]))
        }
    }
}

@MainActor @Test func invalidImageIngressDoesNotFailSceneRequestOrCreateReceipt() async throws {
    let transport = IllustrationTestTransport()
    let controller = SceneController(initialState: try imageState(), transport: transport)
    controller.connect(url: imageServer)
    for _ in 0..<100 where controller.connectionState != .connected { await Task.yield() }
    #expect(controller.request(text: "Explain the structure", requestID: "ordinary"))
    await controller.receive(Data(#"{"type":"illustration.state","status":"invented"}"#.utf8))
    #expect(controller.lastError == nil)
    #expect(controller.lastReceipt == nil)
    #expect(controller.activity != nil)
    controller.disconnect()
}

@MainActor @Test func illustrationRetryControlAndErrorsNeverReplayOrFailOrdinarySceneRequests() async throws {
    let transport = IllustrationTestTransport()
    let controller = SceneController(initialState: try imageState(), transport: transport)
    controller.connect(url: imageServer)
    for _ in 0..<100 where controller.connectionState != .connected { await Task.yield() }
    #expect(controller.request(text: "Create an illustration", requestID: "image-request"))
    for _ in 0..<100 where transport.sent.last?["type"] as? String != "user.request" { await Task.yield() }
    let epoch = controller.acceptedScene.intentEpoch
    var event: [String: Any] = ["type": "illustration.state", "jobId": "image-job", "requestId": "image-request",
        "sceneId": "illustration-scene", "revision": 0, "intentEpoch": epoch, "componentNodeIds": [], "status": "generating"]
    await controller.receive(try JSONSerialization.data(withJSONObject: event))
    #expect(controller.illustration?.phase == .generating)
    #expect(controller.request(text: "Explain this more simply", requestID: "ordinary-followup"))
    #expect(controller.illustration?.phase == .generating)
    event["status"] = "failed"
    event["error"] = "Provider was unavailable."
    await controller.receive(try JSONSerialization.data(withJSONObject: event))
    for _ in 0..<100 where transport.sent.filter({ $0["type"] as? String == "user.request" }).count < 2 { await Task.yield() }
    controller.retryIllustration()
    for _ in 0..<100 where transport.sent.last?["type"] as? String != "illustration.retry" { await Task.yield() }
    #expect(transport.sent.filter { $0["type"] as? String == "user.request" }.count == 2)
    #expect(transport.sent.last?["jobId"] as? String == "image-job")
    await controller.receive(Data(#"{"type":"session.error","code":"illustration_retry_rejected","message":"Please request a new illustration."}"#.utf8))
    #expect(controller.lastError == nil)
    #expect(controller.activity != nil)
    #expect(controller.lastReceipt == nil)
    #expect(controller.illustration?.phase == .failed("Please request a new illustration."))
    controller.disconnect()
    #expect(controller.illustration == nil)
}

@MainActor @Test func installedSceneRevisionRetiresActiveIllustrationAndFencesLateState() async throws {
    let transport = IllustrationTestTransport()
    let initial = try PreviewFixture.sceneState()
    let controller = SceneController(initialState: initial, transport: transport)
    controller.connect(url: imageServer)
    for _ in 0..<100 where controller.connectionState != .connected { await Task.yield() }
    #expect(controller.request(text: "Illustrate the fan", requestID: "image-request"))
    let imageEpoch = controller.acceptedScene.intentEpoch
    let event: [String: Any] = ["type": "illustration.state", "jobId": "image-job", "requestId": "image-request",
        "sceneId": initial.sceneId, "revision": initial.revision, "intentEpoch": imageEpoch,
        "componentNodeIds": ["fixture_fan"], "status": "generating"]
    await controller.receive(try JSONSerialization.data(withJSONObject: event))
    #expect(controller.illustration?.componentNames == ["Preview cooling fan"])
    #expect(controller.request(text: "Hide the fan", requestID: "edit-request"))
    var patch = ScenePatch(requestId: "edit-request", sceneId: initial.sceneId,
        intentEpoch: controller.acceptedScene.intentEpoch, baseRevision: initial.revision, payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)])
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    await controller.receive(try JSONEncoder().encode(ClientMessage.scenePatch(patch)))
    #expect(controller.acceptedScene.revision == initial.revision + 1)
    #expect(controller.illustration == nil)
    await controller.receive(try JSONSerialization.data(withJSONObject: event))
    #expect(controller.illustration == nil)
    controller.disconnect()
}

@MainActor @Test func artifactProvenanceMustMatchAdmittedRevisionBeforeDownload() throws {
    let images = IllustrationSession()
    let scene = try imageState()
    images.register(requestID: "image-request", scene: scene)
    images.receive(imageEvent(), scene: scene, serverURL: imageServer, authToken: nil)
    var event = imageEvent(status: .ready)
    let hash = String(repeating: "a", count: 64)
    event.artifact = IllustrationArtifact(artifactId: "sha256:\(hash)", sha256: hash,
        mimeType: "image/png", width: 1024, height: 1024, byteCount: 100,
        model: "gpt-image-2.5-flare", sourceRevision: 1, path: "/illustrations/artifacts/\(hash).png",
        createdAt: "2026-09-08T12:00:00Z")
    images.receive(event, scene: scene, serverURL: imageServer, authToken: nil)
    #expect(images.presentation?.artifact == nil)
    #expect(images.presentation?.canRetry == false)
    #expect(images.retry(scene: scene, serverURL: imageServer, authToken: nil) == nil)
    #expect(images.presentation?.phase == .failed("The illustration metadata does not match this scene."))
}
