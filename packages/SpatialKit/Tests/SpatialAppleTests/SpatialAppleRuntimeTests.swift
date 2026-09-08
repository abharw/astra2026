import Foundation
import RealityKit
@testable import SpatialApple
import SpatialCore
import Testing

private func explanationData(epoch: UInt64, text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "session.explanation",
        "requestId": "explanation-request",
        "proposalRequestIds": [],
        "intentEpoch": epoch,
        "text": text,
    ])
}

@MainActor
private final class TestSceneTransport: SceneTransport {
    private(set) var state: SceneWebSocketClient.State = .disconnected
    private var onMessage: (@MainActor (Data) async -> Void)?
    private var onStateChange: (@MainActor (SceneWebSocketClient.State) -> Void)?
    private(set) var lastUserRequestID: String?
    private(set) var lastIntentEpoch: UInt64?
    private(set) var sentUserRequestIDs: [String] = []
    var delayedFrameType: String?

    func connect(
        to url: URL,
        onMessage: @escaping @MainActor (Data) async -> Void,
        onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void
    ) {
        self.onMessage = onMessage
        self.onStateChange = onStateChange
        state = .connected
        onStateChange(.connected)
    }

    func send(_ data: Data) async throws {
        guard state == .connected else { throw SceneWebSocketClient.TransportError.notConnected }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String
        else { return }
        if type == delayedFrameType {
            try await Task.sleep(for: .milliseconds(50))
        }
        if type == "user.request" {
            lastUserRequestID = object["requestId"] as? String
            if let lastUserRequestID { sentUserRequestIDs.append(lastUserRequestID) }
            return
        }
        if type == "phone.snapshot" {
            lastIntentEpoch = (object["intentEpoch"] as? NSNumber)?.uint64Value
            return
        }
        guard type == "session.hello", let sessionID = object["sessionId"] as? String else { return }
        let accepted = try JSONSerialization.data(withJSONObject: [
            "type": "session.accepted",
            "protocolVersion": 1,
            "sessionId": sessionID,
            "sceneSchemaVersion": 1,
            "geometrySemanticsVersion": 1,
        ])
        await onMessage?(accepted)
    }

    func emit(_ object: [String: Any]) async throws {
        await onMessage?(try JSONSerialization.data(withJSONObject: object))
    }

    func disconnect() {
        state = .disconnected
        onStateChange?(.disconnected)
    }
}

@MainActor
private func eventually(
    timeout: Duration = .seconds(1),
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now.advanced(by: timeout)
    while clock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Test func offlineRequestFailsFastAndDoesNotRemainSending() throws {
    let controller = SceneController(initialState: try PreviewFixture.sceneState())

    let accepted = controller.request(text: "Hide the fan", requestID: "voice-1")

    #expect(!accepted)
    #expect(controller.activity == nil)
    #expect(controller.lastError == "Connect to the scene backend before sending a request.")
}

@MainActor
@Test func offlineStopAndUndoRemainLocalWithoutTransportErrors() throws {
    let controller = SceneController(initialState: try PreviewFixture.sceneState())

    controller.stop()
    #expect(controller.lastError == nil)
    controller.undo()
    #expect(controller.lastError == nil)
    #expect(controller.activity == nil)
}

@MainActor
@Test func responseTimeoutClearsOnlyTheActiveRequest() async throws {
    let transport = TestSceneTransport()
    let controller = SceneController(
        initialState: try PreviewFixture.sceneState(),
        transport: transport,
        responseTimeout: .milliseconds(25)
    )
    controller.connect(url: try #require(URL(string: "ws://localhost/session")))
    #expect(await eventually { controller.connectionState == .connected })

    #expect(controller.request(text: "Hide the fan", requestID: "voice-timeout"))
    #expect(await eventually { controller.lastError?.contains("did not respond in time") == true })
    #expect(controller.activity == nil)
}

@MainActor
@Test func executionCompletesFromMatchingInstalledReceiptAndExplanation() async throws {
    let transport = TestSceneTransport()
    let controller = SceneController(initialState: try PreviewFixture.sceneState(), transport: transport)
    controller.connect(url: try #require(URL(string: "ws://localhost/session")))
    #expect(await eventually { controller.connectionState == .connected })

    let task = Task { await controller.execute(text: "Hide the fan", requestID: "exec-success") }
    #expect(await eventually { transport.lastUserRequestID == "exec-success" })
    let epoch = try #require(transport.lastIntentEpoch)
    var patch = ScenePatch(
        requestId: "exec-success",
        sceneId: controller.acceptedScene.sceneId,
        intentEpoch: epoch,
        baseRevision: controller.acceptedScene.revision,
        payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)]
    )
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    await controller.receive(try JSONEncoder().encode(ClientMessage.scenePatch(patch)))
    try await transport.emit([
        "type": "session.explanation",
        "requestId": "exec-success",
        "proposalRequestIds": ["exec-success"],
        "intentEpoch": epoch,
        "text": "The fan is hidden.",
    ])

    let result = await task.value
    #expect(result.status == .completed)
    #expect(result.requestID == "exec-success")
    #expect(result.revision == controller.acceptedScene.revision)
    #expect(result.proposalRequestIDs == ["exec-success"])
    #expect(result.explanation == "The fan is hidden.")
    #expect(result.error == nil)
}

@MainActor
@Test func supersededExecutionCancelsAndStaleServiceErrorCannotFinishNewRequest() async throws {
    let transport = TestSceneTransport()
    let controller = SceneController(initialState: try PreviewFixture.sceneState(), transport: transport)
    controller.connect(url: try #require(URL(string: "ws://localhost/session")))
    #expect(await eventually { controller.connectionState == .connected })

    let first = Task { await controller.execute(text: "First", requestID: "exec-first") }
    #expect(await eventually { transport.lastUserRequestID == "exec-first" })
    let second = Task { await controller.execute(text: "Second", requestID: "exec-second") }
    #expect(await eventually { transport.lastUserRequestID == "exec-second" })
    try await transport.emit([
        "type": "session.error", "requestId": "exec-first", "code": "stale", "message": "Old failure",
    ])
    #expect(controller.lastError == nil)
    try await transport.emit([
        "type": "session.error", "requestId": "exec-second", "code": "generation_failed", "message": "Current failure",
    ])

    #expect((await first.value).status == .cancelled)
    let secondResult = await second.value
    #expect(secondResult.status == .failed)
    #expect(secondResult.error == "generation_failed: Current failure")
}

@MainActor
@Test func cancellingExecutionTaskReturnsCancelledWithoutLeakingContinuation() async throws {
    let transport = TestSceneTransport()
    let controller = SceneController(initialState: try PreviewFixture.sceneState(), transport: transport)
    controller.connect(url: try #require(URL(string: "ws://localhost/session")))
    #expect(await eventually { controller.connectionState == .connected })

    let task = Task { await controller.execute(text: "Long request", requestID: "exec-cancel") }
    #expect(await eventually { transport.lastUserRequestID == "exec-cancel" })
    task.cancel()

    let result = await task.value
    #expect(result.status == .cancelled)
    #expect(result.requestID == "exec-cancel")
    #expect(controller.activity == nil)
}

@MainActor
@Test func supersedingWhileSendingNeverDeliversOldRequestText() async throws {
    let transport = TestSceneTransport()
    transport.delayedFrameType = "user.stop"
    let controller = SceneController(initialState: try PreviewFixture.sceneState(), transport: transport)
    controller.connect(url: try #require(URL(string: "ws://localhost/session")))
    #expect(await eventually { controller.connectionState == .connected })

    let first = Task { await controller.execute(text: "Old request", requestID: "exec-old-send") }
    try? await Task.sleep(for: .milliseconds(10))
    let second = Task { await controller.execute(text: "Current request", requestID: "exec-current-send") }
    #expect(await eventually { transport.lastUserRequestID == "exec-current-send" })

    #expect((await first.value).status == .cancelled)
    #expect(transport.sentUserRequestIDs == ["exec-current-send"])
    second.cancel()
    #expect((await second.value).status == .cancelled)
}

@MainActor
@Test func linearMaterialComponentsConvertToSRGBDisplayValues() {
    #expect(MaterialCompiler.linearToSRGB(0) == 0)
    #expect(abs(MaterialCompiler.linearToSRGB(0.003_130_8) - 0.040_449_936) < 0.000_000_1)
    #expect(abs(MaterialCompiler.linearToSRGB(0.18) - 0.461_356_13) < 0.000_001)
    #expect(MaterialCompiler.linearToSRGB(1) == 1)
    #expect(MaterialCompiler.linearToSRGB(-0.5) == 0)
    #expect(MaterialCompiler.linearToSRGB(2) == 1)
}

@MainActor
@Test func acceptedSceneChangesInvalidateInstalledExplanation() async throws {
    var state = try PreviewFixture.sceneState()
    var setupPatch = ScenePatch(
        requestId: "setup-patch",
        sceneId: state.sceneId,
        intentEpoch: state.intentEpoch,
        baseRevision: state.revision,
        payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)]
    )
    setupPatch.payloadHash = try canonicalPayloadHash(for: setupPatch)
    _ = state.apply(.scenePatch(setupPatch))

    let controller = SceneController(initialState: state)
    await controller.receive(try explanationData(epoch: state.intentEpoch, text: "The fan is hidden."))
    #expect(controller.lastExplanation == "The fan is hidden.")

    controller.undo()
    #expect(controller.lastExplanation == nil)

    await controller.receive(try explanationData(
        epoch: controller.acceptedScene.intentEpoch,
        text: "The fixture is restored."
    ))
    #expect(controller.lastExplanation == "The fixture is restored.")

    try controller.loadScene(PreviewFixture.sceneState())
    #expect(controller.lastExplanation == nil)

    await controller.receive(try explanationData(
        epoch: controller.acceptedScene.intentEpoch,
        text: "The fixture is visible."
    ))
    var incomingPatch = ScenePatch(
        requestId: "incoming-patch",
        sceneId: controller.acceptedScene.sceneId,
        intentEpoch: controller.acceptedScene.intentEpoch,
        baseRevision: controller.acceptedScene.revision,
        payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)]
    )
    incomingPatch.payloadHash = try canonicalPayloadHash(for: incomingPatch)
    await controller.receive(try JSONEncoder().encode(ClientMessage.scenePatch(incomingPatch)))
    #expect(controller.lastExplanation == nil)
}

@MainActor
@Test func previewFixtureBuildsASelectableHierarchy() throws {
    let state = try PreviewFixture.sceneState()
    let renderer = SceneRenderer(initialState: state)
    try renderer.loadScene(state)

    let chassis = try #require(renderer.entity(for: "fixture_chassis"))
    let fan = try #require(renderer.entity(for: "fixture_fan"))
    #expect(fan.parent === chassis)
    #expect(chassis is ModelEntity)
    #expect(fan is ModelEntity)
}

@MainActor
@Test func transformOnlyUpdatePreservesNativeEntityIdentity() throws {
    let state = try PreviewFixture.sceneState()
    let renderer = SceneRenderer(initialState: state)
    try renderer.loadScene(state)
    let before = try #require(renderer.entity(for: "fixture_fan"))

    var updated = state.document
    let index = try #require(updated.nodes.firstIndex { $0.nodeId == "fixture_fan" })
    updated.nodes[index].transform.translation = Vec3(0.12, 0.07, 0)
    try renderer.loadScene(updated)

    let after = try #require(renderer.entity(for: "fixture_fan"))
    #expect(before === after)
    #expect(after.position.x == Float(0.12))
}

@MainActor
@Test func everyV1ProceduralRecipeBuildsNativeMesh() throws {
    let recipes: [GeometryRecipe] = [
        .box(size: Vec3(0.2, 0.1, 0.3)),
        .sphere(radius: 0.1, segments: 16),
        .cylinder(radius: 0.08, height: 0.2, radialSegments: 16),
        .cone(bottomRadius: 0.1, topRadius: 0.025, height: 0.2, radialSegments: 16),
        .tube(points: [Vec3(0, 0, 0), Vec3(0.1, 0.05, 0), Vec3(0.2, 0.05, 0.1)], radius: 0.01, radialSegments: 12),
        .arrow(start: Vec3(0, 0, 0), end: Vec3(0.2, 0.15, 0.1), shaftRadius: 0.01, headRadius: 0.025, headLength: 0.06, radialSegments: 12),
    ]
    let compiler = GeometryCompiler()

    for (index, recipe) in recipes.enumerated() {
        let definition = GeometryDefinition(
            geometryId: "geometry_\(index)",
            contentHash: try canonicalContentHash(for: recipe, geometrySemanticsVersion: 1),
            recipe: recipe
        )
        let resource = try compiler.resource(for: definition)
        #expect(resource.bounds.extents.x > 0)
        #expect(resource.bounds.extents.y > 0)
        #expect(resource.bounds.extents.z > 0)
    }
}
