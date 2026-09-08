import Foundation
import Testing

@testable import SpatialCore

@Suite struct FlowContractTests {
  private let provenance = Provenance(origin: .generated, factualSupport: .illustrative)

  private func flow(
    source: String = "source", target: String = "target", routePoints: [Vec3] = [],
    direction: FlowDirection = .forward, width: Double = 0.01, label: String = "Energy",
    animated: Bool = true
  ) -> FlowRecipe {
    FlowRecipe(
      source: FlowAttachment(nodeId: source, localPoint: Vec3(0, 0, 0)),
      target: FlowAttachment(nodeId: target, localPoint: Vec3(0, 1, 0)),
      routePoints: routePoints, direction: direction, width: width, label: label,
      animated: animated)
  }

  private func definition(_ recipe: FlowRecipe, id: String = "flow_geometry") throws
    -> GeometryDefinition
  {
    let geometry = GeometryRecipe.flow(recipe)
    return GeometryDefinition(
      geometryId: id, contentHash: try canonicalContentHash(for: geometry), recipe: geometry)
  }

  private func node(
    _ id: String, parent: String? = nil, geometry: String? = nil, visible: Bool = true
  ) -> SceneNode {
    SceneNode(
      nodeId: id, parentId: parent, geometryId: geometry, isVisible: visible,
      semantic: NodeSemantic(name: id), provenance: provenance)
  }

  private func scene(_ recipe: FlowRecipe? = nil) throws -> SceneDocument {
    SceneDocument(
      documentId: "flow_document", geometryDefinitions: [try definition(recipe ?? flow())],
      nodes: [node("source"), node("target"), node("annotation", geometry: "flow_geometry")])
  }

  private func patch(
    _ operations: [SceneOperation], requestId: String = "patch", revision: UInt64 = 0
  ) throws -> ScenePatch {
    var patch = ScenePatch(
      requestId: requestId, sceneId: "flow_scene", intentEpoch: 0, baseRevision: revision,
      payloadHash: "", operations: operations)
    patch.payloadHash = try canonicalPayloadHash(for: patch)
    return patch
  }

  private func wireObject() throws -> [String: Any] {
    try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(scene())) as? [String: Any])
  }

  private func replacingRecipe(
    in object: [String: Any], with mutate: (inout [String: Any]) throws -> Void
  ) throws -> Data {
    var object = object
    var definitions = try #require(object["geometryDefinitions"] as? [[String: Any]])
    var recipe = try #require(definitions[0]["recipe"] as? [String: Any])
    try mutate(&recipe)
    definitions[0]["recipe"] = recipe
    object["geometryDefinitions"] = definitions
    return try JSONSerialization.data(withJSONObject: object)
  }

  @Test func flowRoundTripsInDocumentsAndPatches() throws {
    let original = try scene(flow(routePoints: [Vec3(0.2, 0.4, 0.6)], direction: .reverse))
    let decoder = SceneWireDecoder()
    #expect(try decoder.decodeDocument(from: JSONEncoder().encode(original)) == original)
    let update = try patch([
      .putGeometry(try definition(flow(label: "Power"), id: "new_flow")),
      .setGeometry(nodeId: "annotation", geometryId: "new_flow"),
    ])
    #expect(try decoder.decodeMessage(from: JSONEncoder().encode(update)) == .scenePatch(update))
    #expect(SceneCapability.flow.rawValue == "flow.v1")
  }

  @Test(arguments: [
    "source.nodeId", "source.localPoint", "target.nodeId", "target.localPoint", "routePoints",
    "direction", "width", "label", "animated",
  ])
  func flowContentHashIncludesEveryAuthoredField(field: String) throws {
    let original = flow()
    var changed = original
    switch field {
    case "source.nodeId": changed.source.nodeId = "other_source"
    case "source.localPoint": changed.source.localPoint = Vec3(0.1, 0, 0)
    case "target.nodeId": changed.target.nodeId = "other_target"
    case "target.localPoint": changed.target.localPoint = Vec3(0, 1.1, 0)
    case "routePoints": changed.routePoints = [Vec3(0.1, 0.2, 0.3)]
    case "direction": changed.direction = .reverse
    case "width": changed.width = 0.02
    case "label": changed.label = "Water"
    default: changed.animated = false
    }
    #expect(
      try canonicalContentHash(for: .flow(original)) != canonicalContentHash(for: .flow(changed)))
  }

  @Test(arguments: ["recipe", "source", "target"])
  func unknownFlowWireFieldsAreRejected(location: String) throws {
    let data = try replacingRecipe(in: wireObject()) { recipe in
      if location == "recipe" {
        recipe["meshURL"] = "untrusted"
      } else {
        var attachment = try #require(recipe[location] as? [String: Any])
        attachment["worldPoint"] = [0, 0, 0]
        recipe[location] = attachment
      }
    }
    #expect(throws: SceneWireError.self) { try SceneWireDecoder().decodeDocument(from: data) }
  }

  @Test(arguments: [
    "source", "target", "routePoints", "direction", "width", "label", "animated",
    "source.nodeId", "source.localPoint", "target.nodeId", "target.localPoint",
  ])
  func missingRequiredFlowWireFieldsAreRejected(field: String) throws {
    let data = try replacingRecipe(in: wireObject()) { recipe in
      let parts = field.split(separator: ".").map(String.init)
      if parts.count == 1 {
        recipe.removeValue(forKey: parts[0])
      } else {
        var attachment = try #require(recipe[parts[0]] as? [String: Any])
        attachment.removeValue(forKey: parts[1])
        recipe[parts[0]] = attachment
      }
    }
    #expect(throws: (any Error).self) { try SceneWireDecoder().decodeDocument(from: data) }
  }

  @Test(arguments: ["direction", "source.localPoint", "routePoints", "animated"])
  func malformedFlowWireValuesAreRejected(field: String) throws {
    let data = try replacingRecipe(in: wireObject()) { recipe in
      switch field {
      case "direction": recipe["direction"] = "bidirectional"
      case "source.localPoint":
        var attachment = try #require(recipe["source"] as? [String: Any])
        attachment["localPoint"] = [0, 1]
        recipe["source"] = attachment
      case "routePoints": recipe["routePoints"] = [[0, 1, 2, 3]]
      default: recipe["animated"] = "true"
      }
    }
    #expect(throws: (any Error).self) { try SceneWireDecoder().decodeDocument(from: data) }
  }

  @Test(arguments: [-0.01, 0, 0.000_999, 0.250_001])
  func widthOutsidePhysicalRangeIsRejected(width: Double) throws {
    let document = try scene(flow(width: width))
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(document) }
  }

  @Test(arguments: [0.001, 0.25])
  func widthBoundaryIsAccepted(width: Double) throws {
    try SceneValidator().validate(scene(flow(width: width)))
  }

  @Test func labelBudgetCountsUTF8Bytes() throws {
    try SceneValidator().validate(scene(flow(label: "")))
    try SceneValidator().validate(scene(flow(label: String(repeating: "é", count: 40))))
    let tooLong = try scene(flow(label: String(repeating: "é", count: 41)))
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(tooLong) }
  }

  @Test func routePointLimitHonorsDefaultAndConfiguredBudgets() throws {
    let points = (0..<9).map { Vec3(Double($0) * 0.1, 0.2, 0.3) }
    try SceneValidator().validate(scene(flow(routePoints: Array(points.prefix(8)))))
    let tooMany = try scene(flow(routePoints: points))
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(tooMany) }

    let reducedBudget = SceneBudgets(maximumFlowRoutePoints: 2)
    let threePoints = try scene(flow(routePoints: Array(points.prefix(3))))
    #expect(throws: SceneValidationError.self) {
      try SceneValidator(budgets: reducedBudget).validate(threePoints)
    }
  }

  @Test(arguments: ["source", "target", "route"])
  func attachmentAndRouteCoordinatesAreBounded(location: String) throws {
    var recipe = flow()
    switch location {
    case "source": recipe.source.localPoint = Vec3(10_001, 0, 0)
    case "target": recipe.target.localPoint = Vec3(0, -10_001, 0)
    default: recipe.routePoints = [Vec3(0, 0, 10_001)]
    }
    let document = try scene(recipe)
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(document) }
  }

  @Test(arguments: ["missing", "annotation", "descendant", "flow_endpoint"])
  func invalidEndpointBindingsAreRejected(endpoint: String) throws {
    var document = try scene(flow(source: endpoint))
    if endpoint == "descendant" {
      document.nodes += [
        node("child", parent: "annotation"), node("descendant", parent: "child"),
      ]
    } else if endpoint == "flow_endpoint" {
      document.geometryDefinitions.append(try definition(flow(), id: "other_flow"))
      document.nodes.append(node("flow_endpoint", geometry: "other_flow"))
    }
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(document) }
  }

  @Test func sharedRecipeIsValidatedForEachAnnotationInstance() throws {
    let document = SceneDocument(
      documentId: "shared_flow", geometryDefinitions: [try definition(flow())],
      nodes: [
        node("source", parent: "second_annotation"), node("target"),
        node("first_annotation", geometry: "flow_geometry"),
        node("second_annotation", geometry: "flow_geometry"),
      ])
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(document) }
  }

  @Test func unusedFlowDefinitionMayReferToAbsentNodes() throws {
    let document = SceneDocument(
      documentId: "unused_flow", geometryDefinitions: [try definition(flow())], nodes: [])
    try SceneValidator().validate(document)
  }

  @Test func sameStructuralNodeSupportsDistinctAttachmentPoints() throws {
    let distinct = flow(source: "source", target: "source")
    try SceneValidator().validate(scene(distinct))

    var coincident = distinct
    coincident.target.localPoint = coincident.source.localPoint
    let invalid = try scene(coincident)
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(invalid) }
  }

  @Test func flowInstanceBudgetIncludesHiddenInstancesSharingGeometry() throws {
    var document = try scene()
    document.nodes = [node("source"), node("target")]
    document.nodes += (0..<32).map {
      node("annotation_\($0)", geometry: "flow_geometry", visible: false)
    }
    try SceneValidator().validate(document)
    document.nodes.append(node("annotation_32", geometry: "flow_geometry", visible: false))
    #expect(throws: SceneValidationError.self) { try SceneValidator().validate(document) }

    document.nodes = [
      node("source"), node("target"), node("first", geometry: "flow_geometry"),
      node("second", geometry: "flow_geometry", visible: false),
    ]
    #expect(throws: SceneValidationError.self) {
      try SceneValidator(budgets: SceneBudgets(maximumFlowInstances: 1)).validate(document)
    }
  }

  @Test func removingBoundEndpointRejectsEntirePatch() throws {
    let initial = try scene()
    var state = try SceneState(document: initial, sceneId: "flow_scene")
    let update = try patch([
      .setVisibility(nodeId: "annotation", isVisible: false), .removeNode(nodeId: "source"),
    ])
    guard case .scene(let receipt) = state.apply(.scenePatch(update)) else {
      Issue.record("expected scene receipt")
      return
    }
    #expect(receipt.status == .rejected)
    #expect(state.document == initial)
    #expect(state.revision == 0)
  }

  @Test func removingAnnotationAndEndpointIsAtomicAndUndoRestoresBindings() throws {
    let initial = try scene()
    var state = try SceneState(document: initial, sceneId: "flow_scene")
    let update = try patch([
      .removeNode(nodeId: "source"), .removeNode(nodeId: "annotation"),
    ])
    guard case .scene(let receipt) = state.apply(.scenePatch(update)) else {
      Issue.record("expected scene receipt")
      return
    }
    #expect(receipt.status == .installed)
    #expect(state.document.nodes.map(\.nodeId) == ["target"])
    #expect(state.revision == 1)
    #expect(state.undo(requestId: "undo_removal").status == .installed)
    #expect(state.document == initial)
    #expect(state.revision == 2)
  }

  @Test func reversingAndHidingRetainNodeIdentityAndUndoRestoresGeometry() throws {
    let initial = try scene()
    let originalNode = try #require(initial.nodes.first { $0.nodeId == "annotation" })
    var state = try SceneState(document: initial, sceneId: "flow_scene")
    let reversed = try definition(flow(direction: .reverse), id: "reversed_geometry")
    let update = try patch([
      .putGeometry(reversed),
      .setGeometry(nodeId: "annotation", geometryId: reversed.geometryId),
      .setVisibility(nodeId: "annotation", isVisible: false),
    ])
    guard case .scene(let receipt) = state.apply(.scenePatch(update)) else {
      Issue.record("expected scene receipt")
      return
    }
    #expect(receipt.status == .installed)
    var expectedNode = originalNode
    expectedNode.geometryId = reversed.geometryId
    expectedNode.isVisible = false
    #expect(state.document.nodes.first { $0.nodeId == "annotation" } == expectedNode)
    #expect(state.document.nodes.count == initial.nodes.count)
    #expect(state.undo(requestId: "undo_reverse").status == .installed)
    #expect(state.document == initial)
  }
}
