import CryptoKit
import Foundation
import Observation
import Network
import RealityKit
import SpatialCore
@testable import SpatialApple
import Testing

@MainActor
private final class DetailTransport: SceneTransport {
    var state: SceneWebSocketClient.State { .connected }
    var sent: [[String: Any]] = []
    func connect(to url: URL, onMessage: @escaping @MainActor (Data) async -> Void,
                 onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void) {}
    func send(_ data: Data) async throws {
        if let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] { sent.append(object) }
    }
    func disconnect() {}
}

private let detailProvenance = Provenance(origin: .authored, factualSupport: .illustrative,
                                        sourceRefs: ["synthetic-desk-lamp-fixture"])

private func detailFixture() throws -> (ImportedAssetDescriptor, ImportedAssetDescriptor, ImportedAssetDetailTemplate) {
    func descriptor(_ filename: String, parts: [ImportedAssetPart]) throws -> ImportedAssetDescriptor {
        let url = try #require(Bundle.module.url(forResource: filename, withExtension: "usdz", subdirectory: "Resources"))
        let data = try Data(contentsOf: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return ImportedAssetDescriptor(assetID: "sha256:\(digest)", sourceURL: url, sha256: digest,
                                       byteCount: data.count, uniqueTriangleCount: 112, parts: parts)
    }
    let overview = try descriptor("lamp-overview", parts: [
        .init(partID: "lamp", name: "Desk lamp", entityName: nil, triangleCount: 112)
    ])
    let detail = try descriptor("lamp-detail", parts: [
        .init(partID: "lamp.base", name: "Weighted base", entityName: "detail_base", triangleCount: 12),
        .init(partID: "lamp.stem", name: "Stem assembly", entityName: "detail_stem", triangleCount: 56),
        .init(partID: "lamp.shade", name: "Lamp shade", entityName: "detail_shade", triangleCount: 44)
    ])
    let centers = [0.04, 0.21, 0.42]
    let children = detail.parts.enumerated().map { index, part in
        // This fixture replaces a whole imported Z-up prototype. Its parent is
        // Y-up, so the authored binding explicitly carries R*T(center).
        ImportedAssetDetailTemplate.Child(partID: part.partID,
            transform: .init(translation: Vec3(0.12, centers[index], 0.08),
                             rotation: Quaternion(-sqrt(0.5), 0, 0, sqrt(0.5))),
            semantic: .init(name: part.name), provenance: detailProvenance)
    }
    let template = ImportedAssetDetailTemplate(detailId: "lamp.parts", name: "Lamp assemblies",
        matches: [.init(assetID: overview.assetID, partID: "lamp")], assetID: detail.assetID, children: children)
    return (overview, detail, template)
}

@MainActor
private func detailOperations(_ template: ImportedAssetDetailTemplate, target: String) throws -> [SceneOperation] {
    var operations: [SceneOperation] = [.setGeometry(nodeId: target, geometryId: nil), .setMaterial(nodeId: target, materialId: nil)]
    for child in template.children {
        let geometryID = "fixture.geometry.\(child.partID)"
        let recipe = GeometryRecipe.importedAsset(assetID: template.assetID, partID: child.partID)
        operations.append(.putGeometry(.init(geometryId: geometryID, contentHash: try canonicalContentHash(for: recipe), recipe: recipe)))
        operations.append(.createNode(.init(nodeId: "\(target).\(child.partID)", parentId: target,
            geometryId: geometryID, transform: child.transform, semantic: child.semantic, provenance: child.provenance)))
    }
    return operations
}

@MainActor
private func patchData(_ operations: [SceneOperation], controller: SceneController, requestID: String) throws -> Data {
    var patch = ScenePatch(requestId: requestID, sceneId: controller.acceptedScene.sceneId,
        intentEpoch: controller.acceptedScene.intentEpoch, baseRevision: controller.acceptedScene.revision,
        payloadHash: "", operations: operations)
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    return try JSONEncoder().encode(ClientMessage.scenePatch(patch))
}

@MainActor
@Test func detailRegistryIsLazyBoundedAndImmutable() throws {
    let (overview, detail, template) = try detailFixture()
    var registry = ImportedAssetDetailRegistry()
    var unavailable = detail
    unavailable.sourceURL = URL(fileURLWithPath: "/does-not-exist.usdz")
    // Registration validates metadata and never touches a file or network.
    try registry.register([template], resources: [unavailable], cacheDirectory: nil)
    let recipe = GeometryRecipe.importedAsset(assetID: overview.assetID, partID: "lamp")
    let geometry = GeometryDefinition(geometryId: "coarse", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
    let document = SceneDocument(documentId: "fixture", geometryDefinitions: [geometry], nodes: [
        .init(nodeId: "lamp1", geometryId: geometry.geometryId, semantic: .init(name: "Desk lamp"), provenance: detailProvenance),
        .init(nodeId: "lamp2", geometryId: geometry.geometryId, semantic: .init(name: "Another lamp"), provenance: detailProvenance)
    ])
    #expect(registry.available(in: document).first?.targetNodeIds == ["lamp1", "lamp2"])
    var invalid = template
    invalid.children[0].transform.translation.x = .nan
    #expect(throws: (any Error).self) { try registry.register([invalid], resources: [], cacheDirectory: nil) }
    invalid = template
    invalid.children[0].partID = "unapproved-part"
    #expect(throws: ImportedAssetError.self) { try registry.register([invalid], resources: [], cacheDirectory: nil) }
    #expect(registry.templates == [template])
}

@MainActor
@Test func lazyDetailPatchPreservesMovedInstanceAndUndoRestoresOverview() async throws {
    let (overview, detail, template) = try detailFixture()
    let transport = DetailTransport()
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: transport)
    try controller.registerAssetDetails([template], resources: [detail])
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group", scale: 0.7)
    let original = try #require(controller.acceptedScene.document.nodes.first { $0.nodeId == "lamp" })
    var duplicate = original
    duplicate.nodeId = "lamp.other"
    duplicate.transform.translation.x = 0.5
    let movedPose = Transform3D(translation: Vec3(0.1, 0.2, -0.3), rotation: Quaternion(0, sin(0.2), 0, cos(0.2)))
    await controller.receive(try patchData([.createNode(duplicate), .setTransform(nodeId: "lamp", transform: movedPose)], controller: controller, requestID: "move-instance"))
    let before = controller.acceptedScene.document
    let otherEntity = try #require(controller.renderer.entity(for: "lamp.other"))
    #expect(controller.availableAssetDetails.first?.targetNodeIds == ["lamp", "lamp.other"])

    await controller.receive(try patchData(detailOperations(template, target: "lamp"), controller: controller, requestID: "expand-lamp"))
    let after = controller.acceptedScene.document
    #expect(after.nodes.count == before.nodes.count + 3)
    let expanded = try #require(after.nodes.first { $0.nodeId == "lamp" })
    #expect(expanded.transform == movedPose)
    #expect(expanded.parentId == original.parentId)
    #expect(expanded.semantic == original.semantic)
    #expect(expanded.geometryId == nil)
    #expect(after.nodes.first { $0.nodeId == "lamp.other" } == duplicate)
    #expect(controller.renderer.entity(for: "lamp.other") === otherEntity)
    #expect(controller.availableAssetDetails.first?.targetNodeIds == ["lamp.other"])
    #expect(controller.acceptedScene.retainedImportedAssetIDs == [overview.assetID, detail.assetID])
    #expect(transport.sent.last { $0["type"] as? String == "scene.receipt" }?["status"] as? String == "installed")
    #expect(transport.sent.last? ["type"] as? String == "phone.snapshot")

    let childID = "lamp.lamp.shade"
    let childPose = Transform3D(translation: Vec3(0.2, 0.6, 0.08))
    await controller.receive(try patchData([.setTransform(nodeId: childID, transform: childPose)], controller: controller, requestID: "move-child"))
    #expect(controller.acceptedScene.document.nodes.first { $0.nodeId == childID }?.transform == childPose)
    controller.undo()
    #expect(controller.acceptedScene.document == after)
    controller.undo()
    #expect(controller.acceptedScene.document == before)
    #expect(controller.availableAssetDetails.first?.targetNodeIds == ["lamp", "lamp.other"])
    #expect(controller.renderer.entity(for: childID) == nil)
}

@MainActor
@Test func unapprovedDetailPatchDoesNotClearExistingGeometry() async throws {
    let (overview, _, template) = try detailFixture()
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    let before = controller.acceptedScene.document
    await controller.receive(try patchData(detailOperations(template, target: "lamp"), controller: controller, requestID: "unapproved-detail"))
    #expect(controller.acceptedScene.document == before)
    #expect(controller.renderer.document == before)
    if case let .scene(receipt) = controller.lastReceipt {
        #expect(receipt.rejection?.code == "native_preparation_failed")
    } else { Issue.record("Expected rejected scene receipt") }
}

@MainActor
@Test func oneExpandedInstanceKeepsAuthoredRestContextWithoutExpansionEligibility() async throws {
    let (overview, detail, template) = try detailFixture()
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    try controller.registerAssetDetails([template], resources: [detail])
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    await controller.receive(try patchData(detailOperations(template, target: "lamp"), controller: controller, requestID: "only-instance-expand"))
    let moved = Transform3D(translation: Vec3(0.5, 0.5, 0.5))
    await controller.receive(try patchData([.setTransform(nodeId: "lamp.lamp.shade", transform: moved)], controller: controller, requestID: "move-shade"))
    let reference = try #require(controller.availableAssetDetails.first)
    #expect(reference.targetNodeIds.isEmpty)
    #expect(reference.children == template.children)
    #expect(reference.children.last?.transform != moved)
    #expect(controller.acceptedScene.document.nodes.first { $0.nodeId == "lamp.lamp.shade" }?.transform == moved)
}

@MainActor
@Test func stoppingDuringDetailPreparationCannotInstallLateChildren() async throws {
    let (overview, detail, template) = try detailFixture()
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    try controller.registerAssetDetails([template], resources: [detail])
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    let before = controller.acceptedScene.document
    let epoch = controller.acceptedScene.intentEpoch
    withObservationTracking {
        _ = controller.activity
    } onChange: {
        // The first real cache/decode progress event deliberately interrupts
        // this load while its asynchronous native preparation is in flight.
        Task { @MainActor in controller.stop() }
    }
    await controller.receive(try patchData(detailOperations(template, target: "lamp"), controller: controller, requestID: "cancel-detail"))
    #expect(controller.acceptedScene.intentEpoch > epoch)
    #expect(controller.acceptedScene.document == before)
    #expect(controller.renderer.document == before)
    #expect(controller.renderer.entity(for: "lamp.lamp.base") == nil)
    #expect(controller.availableAssetDetails.first?.targetNodeIds == ["lamp"])
    if case let .scene(receipt) = controller.lastReceipt {
        #expect(receipt.status == .rejected)
        #expect(receipt.rejection?.code == "native_commit_superseded")
    } else { Issue.record("Expected a fenced installation receipt") }
}

@MainActor
@Test func failedDetailDigestLeavesOverviewAndUndoUnchanged() async throws {
    let (overview, detail, template) = try detailFixture()
    var corrupt = detail
    corrupt.sha256 = String(repeating: "f", count: 64)
    corrupt.assetID = "sha256:\(corrupt.sha256)"
    var corruptTemplate = template
    corruptTemplate.assetID = corrupt.assetID
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    try controller.registerAssetDetails([corruptTemplate], resources: [corrupt])
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    let before = controller.acceptedScene
    await controller.receive(try patchData(detailOperations(corruptTemplate, target: "lamp"), controller: controller, requestID: "corrupt-detail"))
    #expect(controller.acceptedScene.document == before.document)
    #expect(controller.acceptedScene.revision == before.revision)
    #expect(controller.acceptedScene.retainedImportedAssetIDs == before.retainedImportedAssetIDs)
    if case let .scene(receipt) = controller.lastReceipt {
        #expect(receipt.status == .rejected)
        #expect(receipt.rejection?.code == "native_preparation_failed")
    } else { Issue.record("Expected failed preparation receipt") }
}

@MainActor
@Test func cachedCandidateAssetsRemainLeasedWhileAnotherPackageLoads() async throws {
    let (overview, detail, _) = try detailFixture()
    var alternate = detail
    alternate.sourceURL = try #require(Bundle.module.url(forResource: "lamp-detail-alternate", withExtension: "usdz", subdirectory: "Resources"))
    let alternateData = try Data(contentsOf: alternate.sourceURL)
    alternate.sha256 = SHA256.hash(data: alternateData).map { String(format: "%02x", $0) }.joined()
    alternate.assetID = "sha256:\(alternate.sha256)"
    alternate.byteCount = alternateData.count
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    try controller.registerAssetDetails([], resources: [detail, alternate])
    func definitions(_ descriptor: ImportedAssetDescriptor, _ id: String) throws -> GeometryDefinition {
        let recipe = GeometryRecipe.importedAsset(assetID: descriptor.assetID, partID: "lamp.base")
        return .init(geometryId: id, contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
    }
    let cachedGeometry = try definitions(detail, "cached.detail")
    let newGeometry = try definitions(alternate, "new.detail")
    let preparation = SceneDocument(documentId: "preparation", geometryDefinitions: [cachedGeometry])
    var leases: [String] = []
    try await controller.renderer.prepareImportedResources(for: preparation, approved: [detail.assetID: detail],
        cacheDirectory: nil, didPrepare: { leases.append($0) }, progress: { _ in })
    for id in leases { controller.renderer.finishImportedAssetPreparation(assetID: id) }
    // A is pinned; B is cached but unused. Loading C must not evict B, which
    // this same candidate needs even though B requires no further decoding.
    await controller.receive(try patchData([
        .putGeometry(cachedGeometry), .putGeometry(newGeometry),
        .createNode(.init(nodeId: "cached.child", parentId: "lamp", geometryId: cachedGeometry.geometryId,
                         semantic: .init(name: "Cached part"), provenance: detailProvenance)),
        .createNode(.init(nodeId: "new.child", parentId: "lamp", geometryId: newGeometry.geometryId,
                         semantic: .init(name: "New part"), provenance: detailProvenance))
    ], controller: controller, requestID: "mixed-cache-candidate"))
    #expect(controller.renderer.entity(for: "cached.child") != nil)
    #expect(controller.renderer.entity(for: "new.child") != nil)
    #expect(controller.acceptedScene.retainedImportedAssetIDs == [overview.assetID, detail.assetID, alternate.assetID])
}

@MainActor
private final class HeldAssetHTTPServer {
    let listener: NWListener
    var port: UInt16?
    var receivedRequest = false
    var connections: [NWConnection] = []

    init() throws {
        listener = try NWListener(using: .tcp, on: .any)
        listener.stateUpdateHandler = { [weak self] state in
            guard case .ready = state else { return }
            Task { @MainActor in self?.port = self?.listener.port?.rawValue }
        }
        listener.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in
                guard let self else { return }
                self.connections.append(connection)
                connection.start(queue: .main)
                connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { _, _, _, _ in
                    Task { @MainActor in self.receivedRequest = true }
                }
            }
        }
        listener.start(queue: .main)
    }

    func stop() {
        listener.cancel()
        connections.forEach { $0.cancel() }
    }
}

@MainActor
private func detailEventually(_ condition: @escaping @MainActor () -> Bool) async -> Bool {
    let deadline = ContinuousClock.now.advanced(by: .seconds(2))
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(5))
    }
    return condition()
}

@MainActor
@Test func stoppedAssetDownloadUnblocksTheFollowingSceneMessage() async throws {
    let server = try HeldAssetHTTPServer()
    defer { server.stop() }
    #expect(await detailEventually { server.port != nil })
    let port = try #require(server.port)
    let (overview, detail, template) = try detailFixture()
    var remote = detail
    remote.sourceURL = try #require(URL(string: "http://127.0.0.1:\(port)/held.usdz"))
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    try controller.registerAssetDetails([template], resources: [remote], cacheDirectory: directory)
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "lamp.group")
    let initial = controller.acceptedScene.document
    let data = try patchData(detailOperations(template, target: "lamp"), controller: controller, requestID: "held-detail")
    var followingMessageProcessed = false
    let receiveLoop = Task { @MainActor in
        // Mirrors the transport's ordered await of each incoming frame.
        await controller.receive(data)
        await controller.receive(try patchData([.setVisibility(nodeId: "lamp", isVisible: false)], controller: controller, requestID: "following-message"))
        followingMessageProcessed = true
    }
    #expect(await detailEventually { server.receivedRequest })
    controller.stop()
    #expect(await detailEventually { followingMessageProcessed })
    receiveLoop.cancel()
    try await receiveLoop.value
    #expect(controller.acceptedScene.document.nodes.count == initial.nodes.count)
    #expect(controller.acceptedScene.document.nodes.first { $0.nodeId == "lamp" }?.isVisible == false)
    #expect(controller.renderer.entity(for: "lamp.lamp.base") == nil)
    // The server never sent a response: progress required actual cancellation.
}

/// Exact app resources remain opt-in; ordinary tests exercise the same generic
/// path with the small repository-owned lamp, without downloading third-party CAD.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_APP_ROOT"] != nil))
func approvedAppDetailResourcesExpandOneInstanceThroughExistingPatch() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_APP_ROOT"])
    let directory = URL(fileURLWithPath: path).appendingPathComponent("examples/imported-rack")
    func resource(_ name: String) throws -> ImportedAssetDescriptor {
        var value = try JSONDecoder().decode(ImportedAssetDescriptor.self,
            from: Data(contentsOf: directory.appendingPathComponent(name).appendingPathExtension("json")))
        value.sourceURL = directory.appendingPathComponent("Assets").appendingPathComponent(value.sourceURL.lastPathComponent)
        return value
    }
    let overview = try resource("app-catalog")
    let detail = try resource("detail-catalog")
    let templates = try JSONDecoder().decode([ImportedAssetDetailTemplate].self,
        from: Data(contentsOf: directory.appendingPathComponent("detail-templates.json")))
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "empty"), sceneId: "initial"), transport: DetailTransport())
    try controller.registerAssetDetails(templates, resources: [detail])
    _ = try await controller.loadImportedAsset(overview, rootNodeID: "fixture.root", scale: 0.6 / 2.21)
    let available = try #require(controller.availableAssetDetails.first)
    let targetID = try #require(available.targetNodeIds.first)
    let template = try #require(templates.first { $0.detailId == available.detailId })
    let target = try #require(controller.acceptedScene.document.nodes.first { $0.nodeId == targetID })
    var movedPose = target.transform
    movedPose.translation.z += 0.2
    await controller.receive(try patchData([.setTransform(nodeId: targetID, transform: movedPose)], controller: controller, requestID: "app-move"))
    let before = controller.acceptedScene.document
    let start = ContinuousClock.now
    await controller.receive(try patchData(detailOperations(template, target: targetID), controller: controller, requestID: "app-expand"))
    let duration = start.duration(to: .now)
    let after = controller.acceptedScene.document
    #expect(after.nodes.count == before.nodes.count + template.children.count)
    #expect(after.nodes.first { $0.nodeId == targetID }?.transform == movedPose)
    #expect(after.nodes.first { $0.nodeId == targetID }?.geometryId == nil)
    #expect(controller.availableAssetDetails.first?.targetNodeIds.count == available.targetNodeIds.count - 1)
    #expect(before.nodes.filter { $0.nodeId != targetID } == after.nodes.filter { $0.nodeId != targetID && $0.parentId != targetID })
    for child in template.children {
        let childID = "\(targetID).\(child.partID)"
        #expect(controller.renderer.entity(for: childID) != nil)
        #expect(after.nodes.first { $0.nodeId == childID }?.transform == child.transform)
    }
    controller.undo()
    #expect(controller.acceptedScene.document == before)
    if let reportPath = ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_REPORT"] {
        let report: [String: Any] = [
            "schema": "astra-native-detail-installation/v1", "status": "passed",
            "overviewAssetID": overview.assetID, "detailAssetID": detail.assetID,
            "detailBytes": detail.byteCount, "detailTriangles": detail.uniqueTriangleCount,
            "targetNodeID": targetID, "originalInstances": available.targetNodeIds.count,
            "childrenInstalled": template.children.count, "nodesBefore": before.nodes.count, "nodesAfter": after.nodes.count,
            "prepareAndInstallSeconds": Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
            "checks": ["Target ID/current pose preserved", "Other instances unchanged", "Authored local rest poses retained",
                       "All detail entities installed", "Availability updates for selected instance only", "Undo restores intact overview"],
            "scope": "macOS RealityKit controller; no AR camera or physical device frame-rate measurement"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: reportPath))
    }
}
