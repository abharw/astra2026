import Foundation
import Testing

@testable import SpatialCore

private let provenance = Provenance(origin: .generated, factualSupport: .illustrative)

private func geometry(
  _ id: String = "geometry_box", recipe: GeometryRecipe = .box(size: Vec3(0.4, 0.2, 0.6))
) throws -> GeometryDefinition {
  GeometryDefinition(
    geometryId: id, contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
}

private func node(_ id: String, parent: String? = nil, geometryId: String? = nil) -> SceneNode {
  SceneNode(
    nodeId: id, parentId: parent, geometryId: geometryId, semantic: NodeSemantic(name: id),
    provenance: provenance)
}

private func document(nodes: [SceneNode] = [], geometries: [GeometryDefinition] = [])
  -> SceneDocument
{
  SceneDocument(documentId: "document_test", geometryDefinitions: geometries, nodes: nodes)
}

private func hashed(_ value: GenerationBatch) throws -> GenerationBatch {
  var value = value
  value.payloadHash = try canonicalPayloadHash(for: value)
  return value
}

private func hashed(_ value: ScenePatch) throws -> ScenePatch {
  var value = value
  value.payloadHash = try canonicalPayloadHash(for: value)
  return value
}

private func fixture(_ relativePath: String) throws -> Data {
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<5 { root.deleteLastPathComponent() }
  return try Data(contentsOf: root.appending(path: "contracts/fixtures/\(relativePath)"))
}

@Test func fixedCanonicalHashVectorsAreStable() throws {
  let batch = try SceneWireDecoder().decodeMessage(from: fixture("accepted/generation_batch.json"))
  guard case .generationBatch(let batch) = batch else {
    Issue.record("expected batch")
    return
  }
  #expect(
    try canonicalPayloadHash(for: batch)
      == "747815843c7f19dfe783690a2220d8b6d6fe9b37449b1250e6ece98d16a1f678")

  let patch = try SceneWireDecoder().decodeMessage(from: fixture("accepted/scene_patch.json"))
  guard case .scenePatch(let patch) = patch else {
    Issue.record("expected patch")
    return
  }
  #expect(
    try canonicalPayloadHash(for: patch)
      == "be713f08cdf4a851b1cbde720df96af7d697701eaab9561f60699e2fc7a1f1e6")
  #expect(
    try canonicalContentHash(for: .box(size: Vec3(0.4, 0.2, 0.6)))
      == "10a4501e9bb51222f3d933d4e2b441b2bfa333c67a6d9784af35571168f72fdb")
}

@Test func importedAssetReferencesRoundTripAndHaveStableHashes() throws {
  let recipe = GeometryRecipe.importedAsset(assetID: "asset_fixture", partID: "part_fixture")
  let expectedHash = "0f1b897908b19a74554743fc0b4a11abeabe032a92fb8171e3f3cd8a270746a9"
  #expect(try canonicalContentHash(for: recipe) == expectedHash)
  #expect(
    try canonicalContentHash(for: .importedAsset(assetID: "other_asset", partID: "part_fixture"))
      != expectedHash)
  #expect(
    try canonicalContentHash(for: .importedAsset(assetID: "asset_fixture", partID: "other_part"))
      != expectedHash)
  #expect(
    try canonicalContentHash(for: .importedAsset(assetID: "ab", partID: "c"))
      != canonicalContentHash(for: .importedAsset(assetID: "a", partID: "bc")))

  let decoder = SceneWireDecoder()
  let imported = try decoder.decodeDocument(from: fixture("accepted/imported_asset_document.json"))
  #expect(imported.geometryDefinitions.first?.recipe == recipe)
  #expect(try decoder.decodeDocument(from: JSONEncoder().encode(imported)) == imported)

  let definition = try geometry("imported", recipe: recipe)
  let patch = try hashed(ScenePatch(
    requestId: "import", sceneId: "scene", intentEpoch: 0, baseRevision: 0,
    payloadHash: "", operations: [.putGeometry(definition)]))
  #expect(try decoder.decodeMessage(from: JSONEncoder().encode(patch)) == .scenePatch(patch))
}

@Test func importedAssetReferencesRejectUnboundedIdentifiers() throws {
  let invalid: [GeometryRecipe] = [
    .importedAsset(assetID: "", partID: "part"),
    .importedAsset(assetID: "asset", partID: ""),
    .importedAsset(assetID: String(repeating: "a", count: 129), partID: "part"),
    .importedAsset(assetID: "asset", partID: String(repeating: "é", count: 65)),
  ]
  for recipe in invalid {
    let scene = document(geometries: [try geometry(recipe: recipe)])
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(scene) }
  }
}

@Test func importedAssetWireRejectsAssetPathsAndMissingReferences() throws {
  let data = try fixture("accepted/imported_asset_document.json")
  let original = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
  for change in ["url", "path", "assetId", "missingPart"] {
    var object = original
    var definitions = try #require(object["geometryDefinitions"] as? [[String: Any]])
    var recipe = try #require(definitions[0]["recipe"] as? [String: Any])
    if change == "missingPart" {
      recipe.removeValue(forKey: "partID")
    } else {
      recipe[change] = "untrusted"
    }
    definitions[0]["recipe"] = recipe
    object["geometryDefinitions"] = definitions
    let modified = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try SceneWireDecoder().decodeDocument(from: modified) }
  }
}

@Test func sharedLifecycleFixturesReduceToExpectedState() throws {
  let decoder = SceneWireDecoder()
  let initial = try decoder.decodeDocument(from: fixture("accepted/scene_document.json"))
  var state = try SceneState(
    document: initial, sceneId: "scene_fixture", revision: 7, intentEpoch: 3)

  let begin = try decoder.decodeMessage(from: fixture("accepted/generation_begin.json"))
  let batch = try decoder.decodeMessage(from: fixture("accepted/generation_batch.json"))
  let finish = try decoder.decodeMessage(from: fixture("accepted/generation_finish.json"))
  guard case .generation(let beginReceipt) = state.apply(begin) else {
    Issue.record("expected begin receipt")
    return
  }
  #expect(beginReceipt.status == .accepted)
  guard case .scene(let batchReceipt) = state.apply(batch) else {
    Issue.record("expected batch receipt")
    return
  }
  #expect(batchReceipt.status == .installed)
  guard case .generation(let finishReceipt) = state.apply(finish) else {
    Issue.record("expected finish receipt")
    return
  }
  #expect(finishReceipt.status == .completed)
  #expect(state.revision == 8)
  let expected = try decoder.decodeDocument(
    from: fixture("expected/after_generation_batch.json"))
  #expect(state.document == expected)
}

@Test func negativeZeroHashesAsPositiveZero() throws {
  #expect(
    try canonicalContentHash(for: .box(size: Vec3(-0.0, 1, 1)))
      == canonicalContentHash(for: .box(size: Vec3(0.0, 1, 1))))
}

@Test func wireDecoderRejectsUnknownNestedProperties() throws {
  let json = """
    {"type":"scene.patch","protocolVersion":1,"requestId":"r","sceneId":"s","intentEpoch":0,"baseRevision":0,"payloadHash":"0000000000000000000000000000000000000000000000000000000000000000","operations":[{"op":"set.visibility","nodeId":"n","isVisible":true,"surprise":1}]}
    """
  #expect(throws: SceneWireError.self) {
    try SceneWireDecoder().decodeMessage(from: Data(json.utf8))
  }
}

@Test func wireDecoderRejectsIntegersOutsideJavaScriptSafeRange() {
  let json = """
    {"type":"generation.finish","protocolVersion":1,"requestId":"r","sceneId":"s","generationId":"g","intentEpoch":9007199254740992,"lastSequence":0}
    """
  #expect(throws: SceneWireError.self) {
    try SceneWireDecoder().decodeMessage(from: Data(json.utf8))
  }
}

@Test func documentValidationCoversReferencesCyclesAndAllRecipes() throws {
  let recipes: [GeometryRecipe] = [
    .box(size: Vec3(1, 2, 3)),
    .sphere(radius: 1, segments: 16),
    .cylinder(radius: 1, height: 2, radialSegments: 16),
    .cone(bottomRadius: 1, topRadius: 0, height: 2, radialSegments: 16),
    .tube(points: [Vec3(0, 0, 0), Vec3(0, 1, 0)], radius: 0.1, radialSegments: 8),
    .arrow(
      start: Vec3(0, 0, 0), end: Vec3(0, 1, 0), shaftRadius: 0.02, headRadius: 0.05,
      headLength: 0.2, radialSegments: 8),
    .importedAsset(assetID: "asset_fixture", partID: "part_fixture"),
  ]
  let definitions = try recipes.enumerated().map {
    try geometry("geometry_\($0.offset)", recipe: $0.element)
  }
  try SceneValidator().validate(
    document(
      nodes: [node("group"), node("child", parent: "group", geometryId: "geometry_0")],
      geometries: definitions))

  let cycle = try JSONDecoder().decode(
    SceneDocument.self, from: fixture("rejected/cyclic_document.json"))
  #expect(throws: SceneValidationError.self) { try SceneValidator().validate(cycle) }
}

@Test func sharedGeometryStillCountsEveryVisibleInstance() throws {
  let shared = try geometry()
  let scene = document(
    nodes: [
      node("first", geometryId: shared.geometryId),
      node("second", geometryId: shared.geometryId),
    ],
    geometries: [shared])
  let budgets = SceneBudgets(maximumUniqueTriangles: 12, maximumExpandedTriangles: 23)

  #expect(throws: SceneValidationError.self) {
    try SceneValidator(budgets: budgets).validate(scene)
  }
}

@Test func uniqueTriangleBudgetRejectsManyDenseDefinitions() throws {
  let denseRecipe = GeometryRecipe.sphere(radius: 1, segments: 256)
  let definitions = try [
    geometry("dense_a", recipe: denseRecipe),
    geometry("dense_b", recipe: denseRecipe),
  ]
  let scene = document(geometries: definitions)
  let budgets = SceneBudgets(
    maximumUniqueTriangles: 100_000, maximumExpandedTriangles: 500_000)

  #expect(throws: SceneValidationError.self) {
    try SceneValidator(budgets: budgets).validate(scene)
  }
}

@Test func generationLifecycleIsOrderedIdempotentAndCompletes() throws {
  let root = node("root")
  var state = try SceneState(
    document: document(nodes: [root]), sceneId: "scene", revision: 4, intentEpoch: 2)
  let begin = GenerationBegin(
    requestId: "begin", sceneId: "scene", generationId: "generation", intentEpoch: 2,
    initialBaseRevision: 4, scopeParentNodeId: "root")
  guard case .generation(let beginReceipt) = state.apply(.generationBegin(begin)) else {
    Issue.record("expected generation receipt")
    return
  }
  #expect(beginReceipt.status == .accepted)
  #expect(state.revision == 4)

  let definition = try geometry()
  let batch = try hashed(
    GenerationBatch(
      requestId: "batch", sceneId: "scene", generationId: "generation", intentEpoch: 2, sequence: 1,
      payloadHash: "",
      operations: [
        .putGeometry(definition),
        .createNode(node("child", parent: "root", geometryId: definition.geometryId)),
      ]))
  let first = state.apply(.generationBatch(batch))
  guard case .scene(let firstReceipt) = first else {
    Issue.record("expected scene receipt")
    return
  }
  #expect(firstReceipt.status == .installed)
  #expect(state.revision == 5)

  #expect(state.apply(.generationBatch(batch)) == first)
  #expect(state.revision == 5)

  var changedEpoch = batch
  changedEpoch.intentEpoch = 3
  changedEpoch.payloadHash = try canonicalPayloadHash(for: changedEpoch)
  guard case .scene(let conflict) = state.apply(.generationBatch(changedEpoch)) else {
    Issue.record("expected conflict")
    return
  }
  #expect(conflict.status == .rejected)
  #expect(conflict.rejection?.code == "request_id_conflict")
  #expect(state.revision == 5)

  let finish = GenerationFinish(
    requestId: "finish", sceneId: "scene", generationId: "generation", intentEpoch: 2,
    lastSequence: 1)
  guard case .generation(let finishReceipt) = state.apply(.generationFinish(finish)) else {
    Issue.record("expected finish receipt")
    return
  }
  #expect(finishReceipt.status == .completed)
  #expect(finishReceipt.committedSequence == 1)
  #expect(state.revision == 5)
}

@Test func finishWaitsForDeclaredSequence() throws {
  var state = try SceneState(document: document(), sceneId: "scene")
  _ = state.apply(
    .generationBegin(
      GenerationBegin(
        requestId: "begin", sceneId: "scene", generationId: "g", intentEpoch: 0,
        initialBaseRevision: 0)))
  let finish = GenerationFinish(
    requestId: "finish", sceneId: "scene", generationId: "g", intentEpoch: 0, lastSequence: 1)
  guard case .generation(let receipt) = state.apply(.generationFinish(finish)) else {
    Issue.record("expected generation receipt")
    return
  }
  #expect(receipt.status == .rejected)
  #expect(receipt.rejection?.code == "sequence_incomplete")
  #expect(state.revision == 0)
}

@Test func epochSupersessionFencesNewOldWork() throws {
  var state = try SceneState(document: document(), sceneId: "scene")
  _ = state.apply(
    .generationBegin(
      GenerationBegin(
        requestId: "begin", sceneId: "scene", generationId: "g", intentEpoch: 0,
        initialBaseRevision: 0)))
  state.advanceIntentEpoch()
  let batch = try hashed(
    GenerationBatch(
      requestId: "old", sceneId: "scene", generationId: "g", intentEpoch: 0, sequence: 1,
      payloadHash: "", operations: []))
  guard case .scene(let receipt) = state.apply(.generationBatch(batch)) else {
    Issue.record("expected scene receipt")
    return
  }
  #expect(receipt.status == .rejected)
  #expect(receipt.rejection?.code == "stale_epoch")
  #expect(state.revision == 0)
}

@Test func generationCannotMutatePreexistingNode() throws {
  var state = try SceneState(document: document(nodes: [node("root")]), sceneId: "scene")
  _ = state.apply(
    .generationBegin(
      GenerationBegin(
        requestId: "begin", sceneId: "scene", generationId: "g", intentEpoch: 0,
        initialBaseRevision: 0, scopeParentNodeId: "root")))
  let batch = try hashed(
    GenerationBatch(
      requestId: "batch", sceneId: "scene", generationId: "g", intentEpoch: 0, sequence: 1,
      payloadHash: "", operations: [.setVisibility(nodeId: "root", isVisible: false)]))
  guard case .scene(let receipt) = state.apply(.generationBatch(batch)) else {
    Issue.record("expected scene receipt")
    return
  }
  #expect(receipt.status == .rejected)
  #expect(state.document.nodes[0].isVisible)
}

@Test func patchesUseCurrentStateAndUndoOnlyLatestTransaction() throws {
  var state = try SceneState(document: document(nodes: [node("node")]), sceneId: "scene")
  let moved = Transform3D(translation: Vec3(1, 0, 0))
  let first = try hashed(
    ScenePatch(
      requestId: "patch1", sceneId: "scene", intentEpoch: 0, baseRevision: 0, payloadHash: "",
      operations: [.setTransform(nodeId: "node", transform: moved)]))
  guard case .scene(let firstReceipt) = state.apply(.scenePatch(first)) else {
    Issue.record("expected scene receipt")
    return
  }
  #expect(firstReceipt.status == .installed)

  let second = try hashed(
    ScenePatch(
      requestId: "patch2", sceneId: "scene", intentEpoch: 0, baseRevision: 1, payloadHash: "",
      operations: [.setVisibility(nodeId: "node", isVisible: false)]))
  _ = state.apply(.scenePatch(second))
  #expect(state.document.nodes[0].transform == moved)
  #expect(!state.document.nodes[0].isVisible)

  let undo = state.undo(requestId: "undo")
  #expect(undo.status == .installed)
  #expect(state.revision == 3)
  #expect(state.document.nodes[0].transform == moved)
  #expect(state.document.nodes[0].isVisible)

  let stale = try hashed(
    ScenePatch(
      requestId: "stale", sceneId: "scene", intentEpoch: 0, baseRevision: 1, payloadHash: "",
      operations: []))
  guard case .scene(let staleReceipt) = state.apply(.scenePatch(stale)) else {
    Issue.record("expected scene receipt")
    return
  }
  #expect(staleReceipt.rejection?.code == "revision_conflict")
  #expect(staleReceipt.revision == 3)
}
