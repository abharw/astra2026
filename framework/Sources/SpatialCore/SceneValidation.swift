import Foundation

public struct SceneBudgets: Sendable, Equatable {
  public var maximumOperationsPerBatch: Int
  public var maximumNodesPerBatch: Int
  public var maximumNodesPerDocument: Int
  public var maximumGeometryDefinitions: Int
  public var maximumMaterials: Int
  public var maximumTubePoints: Int
  public var maximumFlowInstances: Int
  public var maximumFlowRoutePoints: Int
  public var maximumUniqueTriangles: Int
  public var maximumExpandedTriangles: Int
  public var maximumAbsoluteCoordinate: Double
  public var maximumDimension: Double

  public init(
    maximumOperationsPerBatch: Int = 128,
    maximumNodesPerBatch: Int = 128,
    maximumNodesPerDocument: Int = 2_000,
    maximumGeometryDefinitions: Int = 2_000,
    maximumMaterials: Int = 512,
    maximumTubePoints: Int = 256,
    maximumFlowInstances: Int = 32,
    maximumFlowRoutePoints: Int = 8,
    maximumUniqueTriangles: Int = 500_000,
    maximumExpandedTriangles: Int = 500_000,
    maximumAbsoluteCoordinate: Double = 10_000,
    maximumDimension: Double = 1_000
  ) {
    self.maximumOperationsPerBatch = maximumOperationsPerBatch
    self.maximumNodesPerBatch = maximumNodesPerBatch
    self.maximumNodesPerDocument = maximumNodesPerDocument
    self.maximumGeometryDefinitions = maximumGeometryDefinitions
    self.maximumMaterials = maximumMaterials
    self.maximumTubePoints = maximumTubePoints
    self.maximumFlowInstances = maximumFlowInstances
    self.maximumFlowRoutePoints = maximumFlowRoutePoints
    self.maximumUniqueTriangles = maximumUniqueTriangles
    self.maximumExpandedTriangles = maximumExpandedTriangles
    self.maximumAbsoluteCoordinate = maximumAbsoluteCoordinate
    self.maximumDimension = maximumDimension
  }

  public static let `default` = SceneBudgets()
}

public enum SceneValidationError: Error, Sendable, Equatable, CustomStringConvertible {
  case unsupportedVersion(String)
  case invalidIdentifier(String)
  case duplicateIdentifier(String)
  case missingReference(String)
  case hierarchyCycle(String)
  case invalidNumber(String)
  case invalidGeometry(String)
  case invalidMaterial(String)
  case budgetExceeded(String)
  case immutableDefinition(String)
  case invalidOperation(String)

  public var description: String {
    switch self {
    case .unsupportedVersion(let value): "unsupported version: \(value)"
    case .invalidIdentifier(let value): "invalid identifier: \(value)"
    case .duplicateIdentifier(let value): "duplicate identifier: \(value)"
    case .missingReference(let value): "missing reference: \(value)"
    case .hierarchyCycle(let value): "hierarchy cycle at: \(value)"
    case .invalidNumber(let value): "invalid number: \(value)"
    case .invalidGeometry(let value): "invalid geometry: \(value)"
    case .invalidMaterial(let value): "invalid material: \(value)"
    case .budgetExceeded(let value): "budget exceeded: \(value)"
    case .immutableDefinition(let value): "immutable definition: \(value)"
    case .invalidOperation(let value): "invalid operation: \(value)"
    }
  }
}

public struct SceneValidator: Sendable {
  public var budgets: SceneBudgets

  public init(budgets: SceneBudgets = .default) { self.budgets = budgets }

  public func validate(_ document: SceneDocument) throws {
    guard document.schemaVersion == 1 else {
      throw SceneValidationError.unsupportedVersion("scene schema \(document.schemaVersion)")
    }
    guard document.geometrySemanticsVersion == 1 else {
      throw SceneValidationError.unsupportedVersion(
        "geometry semantics \(document.geometrySemanticsVersion)")
    }
    try identifier(document.documentId, field: "documentId")
    guard document.nodes.count <= budgets.maximumNodesPerDocument else {
      throw SceneValidationError.budgetExceeded("nodes")
    }
    guard document.geometryDefinitions.count <= budgets.maximumGeometryDefinitions else {
      throw SceneValidationError.budgetExceeded("geometryDefinitions")
    }
    guard document.materials.count <= budgets.maximumMaterials else {
      throw SceneValidationError.budgetExceeded("materials")
    }

    let geometries = try unique(document.geometryDefinitions.map(\.geometryId), label: "geometryId")
    let materials = try unique(document.materials.map(\.materialId), label: "materialId")
    let nodes = try unique(document.nodes.map(\.nodeId), label: "nodeId")
    _ = try unique(document.relationships.map(\.relationshipId), label: "relationshipId")

    for geometry in document.geometryDefinitions {
      try validate(geometry, semanticsVersion: document.geometrySemanticsVersion)
    }
    let triangleCounts = Dictionary(
      uniqueKeysWithValues: document.geometryDefinitions.map {
        ($0.geometryId, triangleEstimate(for: $0.recipe))
      })
    let uniqueTriangles = triangleCounts.values.reduce(0, +)
    guard uniqueTriangles <= budgets.maximumUniqueTriangles else {
      throw SceneValidationError.budgetExceeded("unique mesh triangles")
    }
    let expandedTriangles = document.nodes.reduce(into: 0) { total, node in
      guard node.isVisible, let geometryId = node.geometryId else { return }
      total += triangleCounts[geometryId] ?? 0
    }
    guard expandedTriangles <= budgets.maximumExpandedTriangles else {
      throw SceneValidationError.budgetExceeded("expanded visible-instance triangles")
    }
    for material in document.materials { try validate(material) }
    for node in document.nodes {
      try validate(node)
      if let parent = node.parentId, !nodes.contains(parent) {
        throw SceneValidationError.missingReference("parentId \(parent)")
      }
      if let geometry = node.geometryId, !geometries.contains(geometry) {
        throw SceneValidationError.missingReference("geometryId \(geometry)")
      }
      if let material = node.materialId, !materials.contains(material) {
        throw SceneValidationError.missingReference("materialId \(material)")
      }
    }
    try validateHierarchy(document.nodes)
    try validateFlowBindings(document)
    for relationship in document.relationships {
      try identifier(relationship.relationshipId, field: "relationshipId")
      guard !relationship.kind.isEmpty, relationship.kind.utf8.count <= 128 else {
        throw SceneValidationError.invalidIdentifier("relationship kind")
      }
      guard nodes.contains(relationship.sourceNodeId) else {
        throw SceneValidationError.missingReference("sourceNodeId \(relationship.sourceNodeId)")
      }
      guard nodes.contains(relationship.targetNodeId) else {
        throw SceneValidationError.missingReference("targetNodeId \(relationship.targetNodeId)")
      }
    }
  }

  public func validate(operations: [SceneOperation]) throws {
    guard operations.count <= budgets.maximumOperationsPerBatch else {
      throw SceneValidationError.budgetExceeded("operations")
    }
    let created = operations.reduce(into: 0) { count, operation in
      if case .createNode = operation { count += 1 }
    }
    guard created <= budgets.maximumNodesPerBatch else {
      throw SceneValidationError.budgetExceeded("new nodes")
    }
  }

  private func validate(_ geometry: GeometryDefinition, semanticsVersion: Int) throws {
    try identifier(geometry.geometryId, field: "geometryId")
    guard geometry.contentHash.utf8.count == 64,
      geometry.contentHash.utf8.allSatisfy({
        (48...57).contains($0) || (97...102).contains($0)
      })
    else {
      throw SceneValidationError.invalidGeometry("contentHash for \(geometry.geometryId)")
    }
    let expected = try canonicalContentHash(
      for: geometry.recipe, geometrySemanticsVersion: semanticsVersion)
    guard geometry.contentHash == expected else {
      throw SceneValidationError.invalidGeometry("contentHash mismatch for \(geometry.geometryId)")
    }
    switch geometry.recipe {
    case .importedAsset(let assetID, let partID):
      try identifier(assetID, field: "assetID")
      try identifier(partID, field: "partID")
    case .box(let size): try positive(size, "box size")
    case .sphere(let radius, let segmentCount):
      try positive(radius, "sphere radius")
      try segments(segmentCount)
    case .cylinder(let radius, let height, let radialSegments):
      try positive(radius, "cylinder radius")
      try positive(height, "cylinder height")
      try segments(radialSegments)
    case .cone(let bottomRadius, let topRadius, let height, let radialSegments):
      try nonnegative(bottomRadius, "cone bottomRadius")
      try nonnegative(topRadius, "cone topRadius")
      guard bottomRadius > 0 || topRadius > 0 else {
        throw SceneValidationError.invalidGeometry("cone radii are both zero")
      }
      try positive(height, "cone height")
      try segments(radialSegments)
    case .tube(let points, let radius, let radialSegments):
      guard (2...budgets.maximumTubePoints).contains(points.count) else {
        throw SceneValidationError.invalidGeometry("tube point count")
      }
      try positive(radius, "tube radius")
      try segments(radialSegments)
      for point in points { try bounded(point, "tube point") }
      for (a, b) in zip(points, points.dropFirst()) where squaredDistance(a, b) == 0 {
        throw SceneValidationError.invalidGeometry("zero-length tube segment")
      }
    case .arrow(
      let start, let end, let shaftRadius, let headRadius, let headLength, let radialSegments):
      try bounded(start, "arrow start")
      try bounded(end, "arrow end")
      let length = squaredDistance(start, end).squareRoot()
      guard length > 0 else { throw SceneValidationError.invalidGeometry("zero-length arrow") }
      try positive(shaftRadius, "arrow shaftRadius")
      try positive(headRadius, "arrow headRadius")
      try positive(headLength, "arrow headLength")
      guard headLength <= length else {
        throw SceneValidationError.invalidGeometry("arrow headLength exceeds length")
      }
      try segments(radialSegments)
    case .flow(let flow):
      try identifier(flow.source.nodeId, field: "flow source.nodeId")
      try identifier(flow.target.nodeId, field: "flow target.nodeId")
      try bounded(flow.source.localPoint, "flow source.localPoint")
      try bounded(flow.target.localPoint, "flow target.localPoint")
      guard flow.source != flow.target else {
        throw SceneValidationError.invalidGeometry("identical flow attachments")
      }
      guard flow.routePoints.count <= budgets.maximumFlowRoutePoints else {
        throw SceneValidationError.budgetExceeded("flow route points")
      }
      for point in flow.routePoints { try bounded(point, "flow route point") }
      guard flow.width.isFinite, (0.001...0.25).contains(flow.width) else {
        throw SceneValidationError.invalidGeometry("flow width")
      }
      guard flow.label.utf8.count <= 80 else {
        throw SceneValidationError.invalidGeometry("flow label exceeds 80 UTF-8 bytes")
      }
    }
  }

  private func triangleEstimate(for recipe: GeometryRecipe) -> Int {
    switch recipe {
    case .importedAsset:
      // Core has no asset bytes. Native admission must resolve this reference in its
      // bounded catalog and enforce measured unique and visible-instance triangles,
      // under its separate imported-resource budget before installing a scene.
      0
    case .box:
      12
    case .sphere(_, let segments):
      2 * segments * max(2, segments / 2)
    case .cylinder(_, _, let radialSegments):
      4 * radialSegments
    case .cone(let bottomRadius, let topRadius, _, let radialSegments):
      2 * radialSegments
        + (bottomRadius > 0 ? radialSegments : 0)
        + (topRadius > 0 ? radialSegments : 0)
    case .tube(let points, _, let radialSegments):
      2 * (points.count - 1) * radialSegments
    case .arrow(_, _, _, _, _, let radialSegments):
      8 * radialSegments
    case .flow:
      // A bounded 128-sample, eight-sided path, arrowhead, and four markers.
      // Native admission separately measures renderer-owned text geometry.
      3_000
    }
  }

  private func validateFlowBindings(_ document: SceneDocument) throws {
    let recipes = Dictionary(
      uniqueKeysWithValues: document.geometryDefinitions.map { ($0.geometryId, $0.recipe) })
    let nodes = Dictionary(uniqueKeysWithValues: document.nodes.map { ($0.nodeId, $0) })
    let instances: [(SceneNode, FlowRecipe)] = document.nodes.compactMap { node in
      guard let geometryId = node.geometryId, case .flow(let flow) = recipes[geometryId] else {
        return nil
      }
      return (node, flow)
    }
    guard instances.count <= budgets.maximumFlowInstances else {
      throw SceneValidationError.budgetExceeded("flow instances")
    }
    let annotationIDs = Set(instances.map { $0.0.nodeId })
    for (annotation, flow) in instances {
      for attachment in [flow.source, flow.target] {
        guard let endpoint = nodes[attachment.nodeId] else {
          throw SceneValidationError.missingReference("flow endpoint \(attachment.nodeId)")
        }
        // A flow may follow an assembly or one of its structural parts, but may
        // not bind its own transform back through a descendant or another flow.
        var cursor: SceneNode? = endpoint
        while let current = cursor {
          guard current.nodeId != annotation.nodeId,
            !annotationIDs.contains(current.nodeId)
          else {
            throw SceneValidationError.invalidGeometry(
              "flow \(annotation.nodeId) endpoint \(attachment.nodeId) is not structural")
          }
          cursor = current.parentId.flatMap { nodes[$0] }
        }
      }
    }
  }

  private func validate(_ material: Material) throws {
    try identifier(material.materialId, field: "materialId")
    guard material.baseColorLinear.count == 4 else {
      throw SceneValidationError.invalidMaterial("baseColorLinear requires RGBA")
    }
    guard material.baseColorLinear.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else {
      throw SceneValidationError.invalidMaterial("baseColorLinear")
    }
    guard material.baseColorLinear[3] == 1 else {
      throw SceneValidationError.invalidMaterial("v1 requires alpha 1")
    }
    guard material.metallic.isFinite, (0...1).contains(material.metallic),
      material.roughness.isFinite, (0...1).contains(material.roughness)
    else {
      throw SceneValidationError.invalidMaterial("metallic/roughness")
    }
  }

  private func validate(_ node: SceneNode) throws {
    try identifier(node.nodeId, field: "nodeId")
    if let parent = node.parentId { try identifier(parent, field: "parentId") }
    if let geometry = node.geometryId { try identifier(geometry, field: "geometryId") }
    if let material = node.materialId { try identifier(material, field: "materialId") }
    try bounded(node.transform.translation, "translation")
    try positive(node.transform.scale, "scale")
    let q = node.transform.rotation
    guard [q.x, q.y, q.z, q.w].allSatisfy(\.isFinite) else {
      throw SceneValidationError.invalidNumber("rotation")
    }
    let magnitude = (q.x * q.x + q.y * q.y + q.z * q.z + q.w * q.w).squareRoot()
    guard abs(magnitude - 1) <= 0.000_001 else {
      throw SceneValidationError.invalidNumber("rotation must be a unit quaternion")
    }
    guard !node.semantic.name.isEmpty, node.semantic.name.utf8.count <= 256 else {
      throw SceneValidationError.invalidIdentifier("semantic name")
    }
  }

  private func validateHierarchy(_ nodes: [SceneNode]) throws {
    let parents = Dictionary(uniqueKeysWithValues: nodes.map { ($0.nodeId, $0.parentId) })
    for node in nodes {
      var seen = Set<String>()
      var cursor: String? = node.nodeId
      while let id = cursor {
        guard seen.insert(id).inserted else { throw SceneValidationError.hierarchyCycle(id) }
        cursor = parents[id] ?? nil
      }
    }
  }

  private func unique(_ values: [String], label: String) throws -> Set<String> {
    var result = Set<String>()
    for value in values {
      try identifier(value, field: label)
      guard result.insert(value).inserted else {
        throw SceneValidationError.duplicateIdentifier(value)
      }
    }
    return result
  }

  private func identifier(_ value: String, field: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128 else {
      throw SceneValidationError.invalidIdentifier(field)
    }
  }

  private func bounded(_ value: Vec3, _ field: String) throws {
    guard
      [value.x, value.y, value.z].allSatisfy({
        $0.isFinite && abs($0) <= budgets.maximumAbsoluteCoordinate
      })
    else { throw SceneValidationError.invalidNumber(field) }
  }
  private func positive(_ value: Vec3, _ field: String) throws {
    try positive(value.x, field)
    try positive(value.y, field)
    try positive(value.z, field)
  }
  private func positive(_ value: Double, _ field: String) throws {
    guard value.isFinite, value > 0, value <= budgets.maximumDimension else {
      throw SceneValidationError.invalidNumber(field)
    }
  }
  private func nonnegative(_ value: Double, _ field: String) throws {
    guard value.isFinite, value >= 0, value <= budgets.maximumDimension else {
      throw SceneValidationError.invalidNumber(field)
    }
  }
  private func segments(_ value: Int) throws {
    guard (3...256).contains(value) else { throw SceneValidationError.invalidGeometry("segments") }
  }
  private func squaredDistance(_ a: Vec3, _ b: Vec3) -> Double {
    let x = a.x - b.x
    let y = a.y - b.y
    let z = a.z - b.z
    return x * x + y * y + z * z
  }
}
