import Foundation
import SpatialCore
@testable import SpatialApple
import Testing

private func boundsNode(_ id: String, parent: String? = nil) -> SceneNode {
    SceneNode(nodeId: id, parentId: parent, semantic: NodeSemantic(name: id),
        provenance: Provenance(origin: .authored, factualSupport: .illustrative))
}

@MainActor @Test func measuredBoundsPrioritizeSelectionThenAncestorsAndDescendantsWithinBudget() {
    let document = SceneDocument(documentId: "bounds-priority", nodes: [
        boundsNode("unrelated"), boundsNode("root"), boundsNode("assembly", parent: "root"),
        boundsNode("selected", parent: "assembly"), boundsNode("child-a", parent: "selected"),
        boundsNode("child-b", parent: "selected"), boundsNode("grandchild", parent: "child-a"),
        boundsNode("sibling", parent: "assembly"),
    ])
    #expect(SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: ["selected"]) ==
        ["selected", "assembly", "root", "child-a", "child-b", "grandchild"])
    #expect(SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: ["selected"], maximumCount: 4) ==
        ["selected", "assembly", "root", "child-a"])
    #expect(SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: ["missing", "selected", "selected"]) ==
        ["selected", "assembly", "root", "child-a", "child-b", "grandchild"])
    #expect(SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: []) == [])
    #expect(SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: ["selected"], maximumCount: 0) == [])
}

@MainActor @Test func measuredBoundsPriorityRemainsBoundedForLargeAssemblies() {
    let nodes = [boundsNode("root")] + (0..<200).map { boundsNode("part-\($0)", parent: "root") }
    let document = SceneDocument(documentId: "bounded-context", nodes: nodes)
    let prioritized = SceneController.boundsPriorityNodeIDs(in: document, selectionIDs: ["root"], maximumCount: 1000)
    #expect(prioritized.count == 128)
    #expect(prioritized.first == "root")
    #expect(Set(prioritized).count == prioritized.count)
}

@Test func phoneSnapshotEncodesMeasuredBoundsInTheirAcceptedSceneContext() throws {
    let document = SceneDocument(documentId: "bounds-wire", nodes: [boundsNode("part")])
    let bounds = NodeLocalBounds(nodeId: "part", minimum: Vec3(-0.2, -0.1, -0.3), maximum: Vec3(0.2, 0.1, 0.3))
    var snapshot = PhoneSnapshot(sceneId: "bounds-scene", revision: 7, intentEpoch: 12, document: document)
    let withoutBounds = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    #expect(withoutBounds["nodeLocalBounds"] == nil)
    snapshot.nodeLocalBounds = [bounds]
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as? [String: Any])
    #expect(encoded["sceneId"] as? String == "bounds-scene")
    #expect(encoded["revision"] as? Int == 7)
    #expect(encoded["intentEpoch"] as? Int == 12)
    let records = try #require(encoded["nodeLocalBounds"] as? [[String: Any]])
    #expect(records.count == 1)
    #expect(records[0]["nodeId"] as? String == "part")
    #expect(records[0]["minimum"] as? [Double] == [-0.2, -0.1, -0.3])
    #expect(records[0]["maximum"] as? [Double] == [0.2, 0.1, 0.3])
    #expect(encoded["document"] != nil)
}

@Test func sessionHelloAdvertisesFlowWithoutConflatingIllustrationWithGeometry() throws {
    let hello = SessionHello(sessionId: "flow-session", sceneId: "flow-scene", revision: 0, intentEpoch: 0)
    let encoded = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(hello)) as? [String: Any])
    let capabilities = try #require(encoded["capabilities"] as? [String])
    #expect(capabilities.contains("flow.v1"))
    #expect(capabilities.contains("illustration.v1"))
    #expect(!SceneCapability.allCases.map(\.rawValue).contains("illustration.v1"))
}

@MainActor
private final class BoundsSnapshotTransport: SceneTransport {
    var state: SceneWebSocketClient.State = .disconnected
    var snapshots: [[String: Any]] = []
    var acceptsBeforeHelloSendReturns = false
    var receiver: (@MainActor (Data) async -> Void)?
    private var pendingSessionID: String?

    func connect(to url: URL, onMessage: @escaping @MainActor (Data) async -> Void,
                 onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void) {
        receiver = onMessage
        state = .connected
        onStateChange(.connected)
    }
    func disconnect() { state = .disconnected }
    func send(_ data: Data) async throws {
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        if object["type"] as? String == "session.hello" {
            pendingSessionID = try #require(object["sessionId"] as? String)
            if acceptsBeforeHelloSendReturns { try await acknowledgePendingSession() }
        }
        if object["type"] as? String == "phone.snapshot" {
            snapshots.append(object)
            try await acknowledgePendingSession()
        }
    }

    private func acknowledgePendingSession() async throws {
        guard let sessionID = pendingSessionID else { return }
        pendingSessionID = nil
        await receiver?(try JSONSerialization.data(withJSONObject: [
            "type": "session.accepted", "protocolVersion": 1, "sessionId": sessionID,
            "sceneSchemaVersion": 1, "geometrySemanticsVersion": 1,
        ]))
    }
}

@MainActor
private func waitForBoundsSnapshot(_ condition: @MainActor () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while !condition(), ContinuousClock.now < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor @Test func earlyHandshakeAcceptanceStillSendsInitialMeasuredSnapshot() async throws {
    let initial = try PreviewFixture.sceneState()
    let transport = BoundsSnapshotTransport()
    transport.acceptsBeforeHelloSendReturns = true
    let controller = SceneController(initialState: initial, transport: transport)
    defer { controller.disconnect() }
    try controller.loadScene(initial)
    controller.connect(url: try #require(URL(string: "https://example.com/session")))
    #expect(try await waitForBoundsSnapshot { transport.snapshots.count == 1 && controller.connectionState == .connected })
    let snapshot = try #require(transport.snapshots.first)
    let bounds = try #require(snapshot["nodeLocalBounds"] as? [[String: Any]])
    #expect(Set(bounds.compactMap { $0["nodeId"] as? String }) == ["fixture_fan", "fixture_chassis"])
    #expect(snapshot["sceneId"] as? String == initial.sceneId)
    #expect((snapshot["revision"] as? NSNumber)?.uint64Value == initial.revision)
}

@MainActor @Test func controllerSnapshotsIncludeInstalledMeasuredBoundsBeforeAuthoring() async throws {
    let initial = try PreviewFixture.sceneState()
    let transport = BoundsSnapshotTransport()
    let controller = SceneController(initialState: initial, transport: transport)
    defer { controller.disconnect() }
    try controller.loadScene(initial)
    controller.setSelection(SceneSelection(nodeIDs: ["fixture_fan"]))
    controller.connect(url: try #require(URL(string: "https://example.com/session")))
    #expect(try await waitForBoundsSnapshot { !transport.snapshots.isEmpty && controller.connectionState == .connected })
    let snapshot = try #require(transport.snapshots.last)
    let bounds = try #require(snapshot["nodeLocalBounds"] as? [[String: Any]])
    #expect(bounds.first?["nodeId"] as? String == "fixture_fan")
    #expect(Set(bounds.compactMap { $0["nodeId"] as? String }) == ["fixture_fan", "fixture_chassis"])
    #expect(snapshot["sceneId"] as? String == initial.sceneId)
    #expect((snapshot["revision"] as? NSNumber)?.uint64Value == initial.revision)
    controller.setSelection(SceneSelection(nodeIDs: ["fixture_chassis"]))
    #expect(controller.request(text: "Explain the selected fan", selection: SceneSelection(nodeIDs: ["fixture_fan"])))
    #expect(try await waitForBoundsSnapshot { transport.snapshots.count >= 2 })
    let requestSnapshot = try #require(transport.snapshots.last)
    let requestBounds = try #require(requestSnapshot["nodeLocalBounds"] as? [[String: Any]])
    #expect(requestBounds.first?["nodeId"] as? String == "fixture_fan")
}
