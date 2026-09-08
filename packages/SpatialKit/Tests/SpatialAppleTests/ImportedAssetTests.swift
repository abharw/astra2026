import Foundation
import RealityKit
@testable import SpatialApple
import SpatialCore
import Testing

@MainActor
private final class ImportedAssetTestTransport: SceneTransport {
    var state: SceneWebSocketClient.State { .connected }
    func connect(to url: URL, onMessage: @escaping @MainActor (Data) async -> Void,
                 onStateChange: @escaping @MainActor (SceneWebSocketClient.State) -> Void) {}
    func send(_ data: Data) async throws {}
    func disconnect() {}
}

@MainActor
private func applyAssetPatch(_ operations: [SceneOperation], to controller: SceneController) async throws {
    var patch = ScenePatch(requestId: UUID().uuidString, sceneId: controller.acceptedScene.sceneId,
        intentEpoch: controller.acceptedScene.intentEpoch, baseRevision: controller.acceptedScene.revision,
        payloadHash: "", operations: operations)
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    await controller.receive(try JSONEncoder().encode(ClientMessage.scenePatch(patch)))
}

private func rackDescriptor(url: URL) -> ImportedAssetDescriptor {
    let servers = (1...18).map { index in
        let number = String(format: "%02d", index)
        return ImportedAssetPart(partID: "rack01.server\(number)", name: "Server \(number)",
                                 entityName: "rack01_server\(number)", triangleCount: 129_331,
                                 role: "server", description: "Closed server exterior; parent-space +Z is forward.")
    }
    return ImportedAssetDescriptor(assetID: "sha256:aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba", sourceURL: url,
        sha256: "aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba",
        byteCount: 25_786_225, uniqueTriangleCount: 791_123,
        parts: [.init(partID: "rack01.frame", name: "Rack frame", entityName: nil, triangleCount: 661_792)] + servers,
        name: "Open Rack fixture", description: "Parent coordinates use +X right, +Y up, +Z front.")
}

@MainActor
@Test func unknownImportedReferenceDoesNotMutateInstalledScene() throws {
    let renderer = SceneRenderer()
    let recipe = GeometryRecipe.importedAsset(assetID: "unapproved", partID: "server")
    let document = SceneDocument(documentId: "imported-document", geometryDefinitions: [
        .init(geometryId: "asset", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
    ], nodes: [.init(nodeId: "server", geometryId: "asset", semantic: .init(name: "Server"),
                    provenance: .init(origin: .imported, factualSupport: .referenceBased))])
    #expect(throws: ImportedAssetError.self) { try renderer.loadScene(document) }
    #expect(renderer.document.nodes.isEmpty)
    #expect(renderer.entity(for: "server") == nil)
}

@MainActor
@Test func importedDescriptorRequiresBoundedMeasuredCatalog() throws {
    var descriptor = rackDescriptor(url: URL(fileURLWithPath: "/unused.usdz"))
    try ImportedAssetCatalog.validate(descriptor)
    descriptor.parts[0].triangleCount = 4_000_000
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor = rackDescriptor(url: URL(fileURLWithPath: "/unused.usdz"))
    descriptor.parts[1].partID = descriptor.parts[0].partID
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor = rackDescriptor(url: URL(fileURLWithPath: "/unused.usdz"))
    descriptor.parts[2].entityName = descriptor.parts[1].entityName
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
}

@MainActor
@Test func importedSelectionPolicyValidatesShapeBudgetsAndCoordinates() throws {
    var descriptor = rackDescriptor(url: URL(fileURLWithPath: "/unused.usdz"))
    let box = ImportedAssetSelectionBox(center: Vec3(0.1, 0, 0), size: Vec3(0.05, 0.1, 0.2))
    descriptor.parts[0].selection = ImportedAssetSelection.none
    descriptor.parts[1].selection = .boxes([box, .init(center: Vec3(-0.1, 0, 0), size: box.size)])
    try ImportedAssetCatalog.validate(descriptor)
    let decoded = try JSONDecoder().decode(ImportedAssetDescriptor.self, from: JSONEncoder().encode(descriptor))
    #expect(decoded == descriptor)
    descriptor.parts[1].selection = .boxes([.init(center: Vec3(.nan, 0, 0), size: box.size)])
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor.parts[1].selection = .boxes([.init(center: box.center, size: Vec3(0, 1, 1))])
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor.parts[1].selection = .boxes([])
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor.parts[1].selection = .boxes(Array(repeating: box, count: 65))
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
    descriptor.parts[1].selection = .boxes(Array(repeating: box, count: 64))
    descriptor.parts[2].selection = .boxes(Array(repeating: box, count: 64))
    #expect(throws: ImportedAssetError.self) { try ImportedAssetCatalog.validate(descriptor) }
}

@Test func importedAssetPinsRetainRemovedPartsForUndo() throws {
    let assetID = "sha256:" + String(repeating: "a", count: 64)
    let importedRecipe = GeometryRecipe.importedAsset(assetID: assetID, partID: "part")
    let definition = GeometryDefinition(geometryId: "shape", contentHash: try canonicalContentHash(for: importedRecipe),
                                        recipe: importedRecipe)
    let document = SceneDocument(documentId: "pin-test", geometryDefinitions: [definition], nodes: [
        SceneNode(nodeId: "part", geometryId: "shape", semantic: .init(name: "Imported part"),
                  provenance: .init(origin: .imported, factualSupport: .referenceBased))
    ])
    var state = try SceneState(document: document, sceneId: "pin-scene")
    var patch = ScenePatch(requestId: "remove-part", sceneId: state.sceneId, intentEpoch: 0, baseRevision: 0,
        payloadHash: "", operations: [.removeNode(nodeId: "part")])
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    if case let .scene(receipt) = state.apply(.scenePatch(patch)) {
        #expect(receipt.status == .installed)
    } else { Issue.record("Removing the part must produce a scene receipt") }
    #expect(state.document.nodes.isEmpty)
    #expect(state.retainedImportedAssetIDs == [assetID])
    #expect(state.undo(requestId: "undo-removal").status == .installed)
    #expect(state.document.nodes.map(\.nodeId) == ["part"])
    #expect(state.document.geometryDefinitions[0].recipe == importedRecipe)
}

/// Opt-in native cache policy regression using three independently verified real package variants.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_MANIFEST"] != nil))
func importedAssetCachePreservesPinsAndCyclesThreePackages() async throws {
    let manifestPath = try #require(ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_MANIFEST"])
    let manifestURL = URL(fileURLWithPath: manifestPath)
    let root = manifestURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    let manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
    let variants = try #require(manifest["variants"] as? [[String: Any]])
    let descriptors = try variants.prefix(3).map { variant in
        var value = try #require(variant["catalog"] as? [String: Any])
        let sourcePath = try #require(variant["sourcePath"] as? String)
        value["sourceURL"] = root.appendingPathComponent(sourcePath).absoluteString
        return try JSONDecoder().decode(ImportedAssetDescriptor.self, from: JSONSerialization.data(withJSONObject: value))
    }
    #expect(Set(descriptors.map(\.assetID)).count == 3)
    let first = try #require(descriptors.first)
    let second = descriptors[1]
    let third = descriptors[2]
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let catalog = ImportedAssetCatalog()
    _ = try await catalog.prepare(first, cacheDirectory: directory, replacingScene: true, progress: { _ in })
    catalog.setPinnedAssetIDs([first.assetID])
    catalog.finishPreparing(first.assetID)
    _ = try await catalog.prepare(second, cacheDirectory: directory, replacingScene: true, progress: { _ in })
    catalog.setPinnedAssetIDs([first.assetID, second.assetID]) // Current scene plus undo.
    catalog.finishPreparing(second.assetID)
    var oversized = third
    oversized.assetID = "sha256:" + String(repeating: "f", count: 64)
    oversized.sha256 = String(repeating: "f", count: 64)
    oversized.uniqueTriangleCount = 1_000_000
    oversized.sourceURL = URL(fileURLWithPath: "/must-not-be-loaded.usdz")
    do {
        _ = try await catalog.prepare(oversized, cacheDirectory: directory, replacingScene: true, progress: { _ in })
        Issue.record("Pinned native resources plus the candidate must obey the aggregate admission cost")
    } catch ImportedAssetError.budgetExceeded { }
    _ = try await catalog.prepare(third, cacheDirectory: directory, replacingScene: true, progress: { _ in })
    catalog.purgeUnused() // Staged work and undo must survive a memory warning.
    for descriptor in descriptors {
        _ = try catalog.part(assetID: descriptor.assetID, partID: descriptor.parts[0].partID)
    }
    catalog.finishPreparing(third.assetID) // Simulate a rejected/superseded replacement.
    #expect(throws: ImportedAssetError.self) { try catalog.part(assetID: third.assetID, partID: third.parts[0].partID) }
    _ = try catalog.part(assetID: first.assetID, partID: first.parts[0].partID)
    _ = try catalog.part(assetID: second.assetID, partID: second.parts[0].partID)
    _ = try await catalog.prepare(third, cacheDirectory: directory, replacingScene: true, progress: { _ in })
    catalog.setPinnedAssetIDs([third.assetID])
    catalog.finishPreparing(third.assetID)
    for descriptor in [first, second, third] {
        _ = try await catalog.prepare(descriptor, cacheDirectory: directory, replacingScene: true, progress: { _ in })
        catalog.setPinnedAssetIDs([descriptor.assetID])
        catalog.finishPreparing(descriptor.assetID)
    }
    catalog.purgeUnused()
    _ = try catalog.part(assetID: third.assetID, partID: third.parts[0].partID)
    #expect(throws: ImportedAssetError.self) { try catalog.part(assetID: first.assetID, partID: first.parts[0].partID) }
    #expect(throws: ImportedAssetError.self) { try catalog.part(assetID: second.assetID, partID: second.parts[0].partID) }
}

/// Opt in with the pinned, untracked source file. CI does not download third-party model data.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_USDZ"] != nil))
func actualRackImportPreservesPartsMaterialsCacheAndTransformEdits() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_USDZ"])
    var descriptor = rackDescriptor(url: URL(fileURLWithPath: path))
    if let catalogPath = ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_CATALOG"] {
        descriptor = try JSONDecoder().decode(ImportedAssetDescriptor.self,
            from: Data(contentsOf: URL(fileURLWithPath: catalogPath)))
        descriptor.sourceURL = URL(fileURLWithPath: path)
    }
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "initial"),
        sceneId: "initial-scene"), transport: ImportedAssetTestTransport())
    let report = try await controller.loadImportedAsset(descriptor, rootNodeID: "rack01", scale: 0.6 / 2.21, cacheDirectory: directory)
    if let documentPath = ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_DOCUMENT"] {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(controller.acceptedScene.document)
            .write(to: URL(fileURLWithPath: documentPath), options: .atomic)
    }
    #expect(report.nodeIDs.count == 20)
    #expect(report.expandedTriangleCount == descriptor.parts.reduce(0, { $0 + $1.triangleCount }))
    #expect(!report.usedEntityCache)
    let rootNode = try #require(controller.acceptedScene.document.nodes.first { $0.nodeId == "rack01" })
    #expect(rootNode.semantic.name == (descriptor.name ?? "Imported assembly"))
    #expect(rootNode.semantic.description == descriptor.description)
    let sourcePart = try #require(descriptor.parts.first { $0.partID == "rack01.server03" })
    let importedPartNode = try #require(controller.acceptedScene.document.nodes.first { $0.nodeId == sourcePart.partID })
    #expect(importedPartNode.semantic.role == (sourcePart.role ?? "component"))
    #expect(importedPartNode.semantic.description == sourcePart.description)
    let server = try #require(controller.renderer.entity(for: "rack01.server03"))
    let descendants = ImportedAssetCatalog.descendants(server)
    #expect(descendants.allSatisfy { $0.name != "astra.imported.selection" })
    let model = try #require(descendants.first { $0.components[ModelComponent.self] != nil })
    let originalMaterialCount = try #require(model.components[ModelComponent.self]).materials.count
    #expect(originalMaterialCount > 0)
    #expect(descendants.filter { $0.components[CollisionComponent.self] != nil }.count == 1)
    let frame = try #require(controller.renderer.entity(for: "rack01.frame"))
    #expect(ImportedAssetCatalog.descendants(frame).allSatisfy { $0.components[CollisionComponent.self] == nil })
    controller.setSelection(.init(nodeIDs: ["rack01.server03"]))
    #expect(try #require(model.components[ModelComponent.self]).materials.count == originalMaterialCount)
    let outline = try #require(server.findEntity(named: "astra.imported.selection"))
    let edges = outline.children.compactMap { $0.components[ModelComponent.self] }
    #expect(edges.count == 12)
    #expect(Set(edges.map { ObjectIdentifier($0.mesh) }).count == 1)
    controller.setSelection(.init(nodeIDs: ["rack01.server04"]))
    let nextServer = try #require(controller.renderer.entity(for: "rack01.server04"))
    #expect(nextServer.findEntity(named: "astra.imported.selection") === outline)
    #expect(server.findEntity(named: "astra.imported.selection") == nil)
    controller.setSelection(.init(nodeIDs: ["rack01.server04"]))
    #expect(nextServer.findEntity(named: "astra.imported.selection") === outline)
    controller.setSelection(nil)
    #expect(!outline.isEnabled)
    controller.setSelection(.init(nodeIDs: ["rack01.server03"]))
    var changed = controller.acceptedScene.document
    let index = try #require(changed.nodes.firstIndex { $0.nodeId == "rack01.server03" })
    changed.nodes[index].transform.translation.x += 0.5
    changed.nodes[index].isVisible = false
    try await applyAssetPatch([
        .setTransform(nodeId: "rack01.server03", transform: changed.nodes[index].transform),
        .setVisibility(nodeId: "rack01.server03", isVisible: false)
    ], to: controller)
    #expect(controller.acceptedScene.document == changed)
    #expect(controller.renderer.entity(for: "rack01.server03") === server)
    #expect(ImportedAssetCatalog.descendants(server).contains { $0 === model })
    #expect(!server.isEnabled)
    let importedRevision = controller.acceptedScene.revision
    try await applyAssetPatch([
        .putMaterial(.init(materialId: "yellow", baseColorLinear: [1, 1, 0, 1], metallic: 0, roughness: 0.5)),
        .setMaterial(nodeId: "rack01.server03", materialId: "yellow")
    ], to: controller)
    #expect(controller.acceptedScene.revision == importedRevision)
    #expect(controller.acceptedScene.document.materials.isEmpty)
    if case let .scene(receipt) = controller.lastReceipt {
        #expect(receipt.rejection?.code == "native_preparation_failed")
    } else { Issue.record("The unsupported material override must return a rejected scene receipt") }
    let boxRecipe = GeometryRecipe.box(size: Vec3(0.1, 0.1, 0.1))
    try await applyAssetPatch([
        .putGeometry(.init(geometryId: "explanation-box", contentHash: try canonicalContentHash(for: boxRecipe), recipe: boxRecipe)),
        .createNode(.init(nodeId: "explanation-marker", parentId: "rack01", geometryId: "explanation-box",
                         semantic: .init(name: "Explanation marker"),
                         provenance: .init(origin: .generated, factualSupport: .illustrative)))
    ], to: controller)
    #expect(controller.renderer.entity(for: "explanation-marker") is ModelEntity)
    #expect(controller.renderer.entity(for: "rack01.server03") === server)
    let withinBudget = controller.acceptedScene
    let largestPart = try #require(descriptor.parts.max { $0.triangleCount < $1.triangleCount })
    let copiesExceedingBudget = (ImportedAssetCatalog.maximumExpandedTriangles - report.expandedTriangleCount)
        / largestPart.triangleCount + 1
    #expect(copiesExceedingBudget <= 128)
    let extraServers = (1...copiesExceedingBudget).map { index in
        SceneOperation.createNode(.init(nodeId: "duplicate-server-\(index)", parentId: "rack01",
            geometryId: "imported.\(largestPart.partID)", semantic: .init(name: "Duplicate part"),
            provenance: .init(origin: .generated, factualSupport: .illustrative)))
    }
    try await applyAssetPatch(extraServers, to: controller)
    #expect(controller.acceptedScene == withinBudget)
    #expect(controller.renderer.entity(for: "duplicate-server-1") == nil)
    let existingSceneID = controller.acceptedScene.sceneId
    var rebound = descriptor
    rebound.description = "Changed catalog semantics"
    do {
        try await controller.loadImportedAsset(rebound, rootNodeID: "rack01", cacheDirectory: directory)
        Issue.record("A cached asset's approved semantic descriptor must not be rebound")
    } catch ImportedAssetError.invalidDescriptor {
        #expect(controller.acceptedScene.sceneId == existingSceneID)
    }
    do {
        try await controller.loadImportedAsset(descriptor, rootNodeID: "rack01", cacheDirectory: directory) { phase in
            if phase == .installing { controller.stop() }
        }
        Issue.record("A newer intent must fence the pending asset installation")
    } catch ImportedAssetError.superseded {
        #expect(controller.acceptedScene.sceneId == existingSceneID)
        #expect(controller.renderer.entity(for: "explanation-marker") is ModelEntity)
    }
    let repeated = try await controller.loadImportedAsset(descriptor, rootNodeID: "rack01", scale: 0.6 / 2.21, cacheDirectory: directory)
    #expect(repeated.usedEntityCache)
    let bounds = try #require(controller.renderer.entity(for: "rack01")).visualBounds(relativeTo: nil)
    print("ACTUAL_USDZ_IMPORT seconds=\(report.loadDurationSeconds) install_seconds=\(report.installDurationSeconds) cached_seconds=\(repeated.loadDurationSeconds) nodes=\(report.nodeIDs.count) native_entities=\(report.importedEntityCount) native_models=\(report.importedModelCount) triangles=\(report.expandedTriangleCount) server03_transform=\(changed.nodes[index].transform) bounds_min=\(bounds.min) bounds_max=\(bounds.max)")
    if let evidencePath = ProcessInfo.processInfo.environment["ASTRA_TEST_IMPORTED_EVIDENCE"] {
        let evidence: [String: Any] = [
            "completedAt": ISO8601DateFormatter().string(from: Date()),
            "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "sha256": descriptor.sha256,
            "sourceFilename": URL(fileURLWithPath: path).lastPathComponent,
            "byteCount": report.byteCount,
            "uniqueTriangleCount": descriptor.uniqueTriangleCount,
            "expandedTriangleCount": report.expandedTriangleCount,
            "triangleCountBasis": "Independently measured USD topology, admitted through the approved descriptor; not GPU instrumentation",
            "sceneNodeCount": report.nodeIDs.count,
            "nativeEntityCount": report.importedEntityCount,
            "nativeModelCount": report.importedModelCount,
            "scale": 0.6 / 2.21,
            "freshCatalog": ["preparationSeconds": report.loadDurationSeconds,
                             "installationSeconds": report.installDurationSeconds,
                             "usedFileCache": report.usedFileCache, "usedEntityCache": report.usedEntityCache],
            "cachedEntities": ["preparationSeconds": repeated.loadDurationSeconds,
                               "installationSeconds": repeated.installDurationSeconds,
                               "usedFileCache": repeated.usedFileCache, "usedEntityCache": repeated.usedEntityCache],
            "boundsMinimumMeters": [Double(bounds.min.x), Double(bounds.min.y), Double(bounds.min.z)],
            "boundsMaximumMeters": [Double(bounds.max.x), Double(bounds.max.y), Double(bounds.max.z)],
            "acceptanceChecks": ["18 stable server parts", "authored material count preserved by selection",
                "one lazy selection outline and one shared edge mesh",
                "approved root and part semantics projected", "cached semantic descriptor rebinding rejected",
                "one collider per selectable server and none on enclosing frame", "transform and hide through canonical ScenePatch",
                "native entity and model identity retained", "unsupported material override rejected atomically",
                "procedural marker added alongside imported parts", "excess imported triangles rejected atomically",
                "superseded asset installation rejected", "entity cache reused"],
            "measurementLimits": ["One macOS sample per variant; fresh process/controller and temporary asset cache",
                "Local file import, no network download; OS file cache state is uncontrolled",
                "No ARView or rendered frames; these are native preparation/installation times, not physical-device GPU FPS"]
        ]
        let data = try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: URL(fileURLWithPath: evidencePath), options: .atomic)
    }
}

/// Native gate for a separately exported teaching pack. It does not add the pack to an app or tool catalog.
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_CATALOG"] != nil))
func importedSelectionPolicyBuildsOneCompoundCollider() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_CATALOG"])
    var descriptor = try JSONDecoder().decode(ImportedAssetDescriptor.self,
        from: Data(contentsOf: URL(fileURLWithPath: path)))
    for index in descriptor.parts.indices { descriptor.parts[index].selection = ImportedAssetSelection.none }
    descriptor.parts[0].selection = .boxes([
        .init(center: Vec3(-0.1, 0, 0), size: Vec3(0.05, 0.1, 0.05)),
        .init(center: Vec3(0.1, 0, 0), size: Vec3(0.05, 0.1, 0.05))
    ])
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "proxy-gate"),
        sceneId: "proxy-gate"), transport: ImportedAssetTestTransport())
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    _ = try await controller.loadImportedAsset(descriptor, rootNodeID: "proxy-test", cacheDirectory: directory)
    let root = try #require(controller.renderer.entity(for: "proxy-test"))
    let colliders = ImportedAssetCatalog.descendants(root).compactMap { $0.components[CollisionComponent.self] }
    #expect(colliders.count == 1)
    #expect(colliders.first?.shapes.count == 2)
    let disabledPartID = descriptor.parts[1].partID
    controller.setSelection(.init(nodeIDs: [disabledPartID]))
    let disabledPart = try #require(controller.renderer.entity(for: disabledPartID))
    #expect(disabledPart.findEntity(named: "astra.imported.selection")?.isEnabled == true)
    #expect(ImportedAssetCatalog.descendants(disabledPart).allSatisfy { $0.components[CollisionComponent.self] == nil })
}

@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_CATALOG"] != nil))
func serverDetailNativeExtractionPreservesGroupsAndCoordinates() async throws {
    let path = try #require(ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_CATALOG"])
    let catalogData = try Data(contentsOf: URL(fileURLWithPath: path))
    let descriptor = try JSONDecoder().decode(ImportedAssetDescriptor.self, from: catalogData)
    #expect(descriptor.parts.count == 9)
    #expect(descriptor.parts.allSatisfy { $0.entityName != nil })
    let raw = try await Entity(contentsOf: descriptor.sourceURL)
    let rawEntities = ImportedAssetCatalog.descendants(raw)
    let rawModels = rawEntities.filter { $0.components[ModelComponent.self] != nil }
    var ownedModels = Set<ObjectIdentifier>()
    var rawParts: [String: Entity] = [:]
    for part in descriptor.parts {
        let name = try #require(part.entityName)
        let matches = rawEntities.filter { $0.name == name }
        #expect(matches.count == 1)
        let root = try #require(matches.first)
        rawParts[part.partID] = root
        for entity in ImportedAssetCatalog.descendants(root) where entity.components[ModelComponent.self] != nil {
            #expect(ownedModels.insert(ObjectIdentifier(entity)).inserted)
        }
    }
    #expect(ownedModels.count == rawModels.count)
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let controller = SceneController(initialState: try SceneState(document: .init(documentId: "detail-gate"),
        sceneId: "detail-gate"), transport: ImportedAssetTestTransport())
    let report = try await controller.loadImportedAsset(descriptor, rootNodeID: "detail-preview", scale: 1, cacheDirectory: directory)
    #expect(report.nodeIDs.count == 10)
    #expect(report.importedModelCount == rawModels.count)
    #expect(controller.acceptedScene.document.nodes.filter { $0.parentId == "detail-preview" }.count == 9)
    var partReports: [[String: Any]] = []
    func coordinates(_ value: SIMD3<Float>) -> [Double] { [Double(value.x), Double(value.y), Double(value.z)] }
    func matrixDelta(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        var delta: Float = 0
        for column in 0..<4 { for row in 0..<4 { delta = max(delta, abs(a[column][row] - b[column][row])) } }
        return delta
    }
    var actualTriangles = 0
    for part in descriptor.parts {
        let source = try #require(rawParts[part.partID])
        let installed = try #require(controller.renderer.entity(for: part.partID))
        let sourceModels = ImportedAssetCatalog.descendants(source).compactMap { $0.components[ModelComponent.self] }
        let installedModels = ImportedAssetCatalog.descendants(installed).compactMap { $0.components[ModelComponent.self] }
        #expect(sourceModels.count == installedModels.count)
        let sourceBounds = source.visualBounds(relativeTo: nil)
        let installedBounds = installed.visualBounds(relativeTo: nil)
        let boundsDelta = max(simd_reduce_max(abs(sourceBounds.min - installedBounds.min)),
                              simd_reduce_max(abs(sourceBounds.max - installedBounds.max)))
        #expect(boundsDelta < 0.00001)
        let transformDelta = matrixDelta(source.transformMatrix(relativeTo: nil), installed.transformMatrix(relativeTo: nil))
        #expect(transformDelta < 0.00001)
        let collisions = ImportedAssetCatalog.descendants(installed).compactMap { $0.components[CollisionComponent.self] }
        let expectedShapeCount: Int
        switch part.selection {
        case nil: expectedShapeCount = 1
        case .none?: expectedShapeCount = 0
        case .boxes(let boxes)?: expectedShapeCount = boxes.count
        }
        #expect(collisions.count == (expectedShapeCount > 0 ? 1 : 0))
        #expect(collisions.reduce(0, { $0 + $1.shapes.count }) == expectedShapeCount)
        var nativeTriangleCount = 0
        var materialCount = 0
        var meshPartCount = 0
        for (a, b) in zip(sourceModels, installedModels) {
            #expect(a.materials.count == b.materials.count)
            #expect(a.mesh.expectedMaterialCount == b.mesh.expectedMaterialCount)
            let sourceMeshParts = a.mesh.contents.models.flatMap { $0.parts }
            let installedMeshParts = b.mesh.contents.models.flatMap { $0.parts }
            #expect(sourceMeshParts.count == installedMeshParts.count)
            #expect(sourceMeshParts.map(\.materialIndex) == installedMeshParts.map(\.materialIndex))
            for (sourceMeshPart, installedMeshPart) in zip(sourceMeshParts, installedMeshParts) {
                let sourceIndices = sourceMeshPart.triangleIndices.map { Array($0) } ?? []
                let installedIndices = installedMeshPart.triangleIndices.map { Array($0) } ?? []
                #expect(sourceIndices == installedIndices)
            }
            nativeTriangleCount += installedMeshParts.reduce(0) { $0 + ($1.triangleIndices?.count ?? 0) / 3 }
            materialCount += b.materials.count
            meshPartCount += installedMeshParts.count
        }
        #expect(nativeTriangleCount == part.triangleCount)
        actualTriangles += nativeTriangleCount
        let rotation = simd_float4x4(simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)))
        let childLocal = simd_inverse(rotation) * installed.transformMatrix(relativeTo: nil)
        let sourceSpaceRotation = Transform(matrix: childLocal).rotation
        #expect(abs(sourceSpaceRotation.real) > 0.9999)
        partReports.append(["partID": part.partID, "entityName": part.entityName!, "nativeTriangles": nativeTriangleCount,
            "nativeModelCount": installedModels.count, "nativeMeshPartCount": meshPartCount,
            "materialSlotCount": materialCount, "colliderCount": collisions.count,
            "collisionShapeCount": expectedShapeCount,
            "worldBoundsMeters": ["minimum": coordinates(installedBounds.min), "maximum": coordinates(installedBounds.max)],
            "nativeTransformMaximumDelta": Double(transformDelta), "nativeBoundsMaximumDeltaMeters": Double(boundsDelta),
            "sourceSpaceChildTranslationMeters": [Double(childLocal.columns.3.x), Double(childLocal.columns.3.y), Double(childLocal.columns.3.z)],
            "sourceSpaceChildRotationQuaternion": [Double(sourceSpaceRotation.imag.x), Double(sourceSpaceRotation.imag.y),
                Double(sourceSpaceRotation.imag.z), Double(sourceSpaceRotation.real)]])
    }
    #expect(actualTriangles == descriptor.uniqueTriangleCount)
    if let output = ProcessInfo.processInfo.environment["ASTRA_TEST_DETAIL_EVIDENCE"] {
        let evidence: [String: Any] = ["schema": "astra-server-detail-native-gate/v1", "status": "passed",
            "measuredAt": ISO8601DateFormatter().string(from: Date()), "platform": ProcessInfo.processInfo.operatingSystemVersionString,
            "sha256": descriptor.sha256, "byteCount": descriptor.byteCount, "assetFile": "runtime/processed-assets/server-teaching.usdz",
            "catalogFile": "runtime/processed-assets/server-teaching.catalog.json", "applicationIntegrated": false, "toolIntegrated": false,
            "semanticPartCount": descriptor.parts.count, "sceneNodeCount": report.nodeIDs.count, "nativeModelCount": report.importedModelCount,
            "nativeEntityCount": report.importedEntityCount, "nativeTriangleCount": actualTriangles,
            "nativePreparationSeconds": report.loadDurationSeconds, "nativeInstallationSeconds": report.installDurationSeconds,
            "partBindingsCoverAllNativeModels": ownedModels.count == rawModels.count, "partBindingsHaveNoSharedDescendants": true,
            "parts": partReports,
            "coordinateContract": "Standalone loader preserves RealityKit Z-up conversion. Before attaching beneath a server wrapper that already has that rotation, use inverse(sourceToRealityKitRotation) * importedPartWorld as the child local transform; preserve the server wrapper transform.",
            "scope": "macOS RealityKit load and standalone SceneController extraction. No ARView, rendered image, iPhone/iPad GPU performance, or installed app/tool subtree support.",
            "limitations": ["Bounding boxes of functional groups can overlap physically; non-overlap here means distinct subtree ownership, not disjoint volume.",
                "Comparison checks native geometry indices, slot mappings/counts, transforms and bounds. It does not prove all source colors, mechanical fidelity, or factual component identities.",
                "This gate does not wire detail loading into the live tool or existing server hierarchy."]]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}
