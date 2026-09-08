import Foundation

public enum SceneWireError: Error, Sendable, Equatable, CustomStringConvertible {
  case messageTooLarge(Int)
  case invalidJSON
  case unknownProperty(path: String, property: String)
  case invalidValue(path: String)

  public var description: String {
    switch self {
    case .messageTooLarge(let bytes): "wire message exceeds 262144 bytes: \(bytes)"
    case .invalidJSON: "wire message is not a JSON object"
    case .unknownProperty(let path, let property): "unknown property \(property) at \(path)"
    case .invalidValue(let path): "value violates the v1 wire contract at \(path)"
    }
  }
}

public struct SceneWireDecoder: Sendable {
  public static let maximumMessageBytes = 256 * 1_024

  public init() {}

  public func decodeMessage(from data: Data) throws -> ClientMessage {
    let root = try rootObject(data)
    try inspectEnvelope(root, path: "$")
    let message = try JSONDecoder().decode(ClientMessage.self, from: data)
    try validateEnvelopeBounds(message)
    return message
  }

  public func decodeDocument(from data: Data, budgets: SceneBudgets = .default) throws
    -> SceneDocument
  {
    let root = try rootObject(data)
    try inspectDocument(root, path: "$")
    let document = try JSONDecoder().decode(SceneDocument.self, from: data)
    try SceneValidator(budgets: budgets).validate(document)
    return document
  }

  public func decodeReceipt(from data: Data) throws -> ApplyReceipt {
    let root = try rootObject(data)
    guard let type = root["type"] as? String else { throw SceneWireError.invalidJSON }
    switch type {
    case "scene.receipt":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "sceneId", "generationId", "requestId", "sequence", "status",
          "revision", "affectedNodeIds", "rejection",
        ], path: "$")
    case "generation.receipt":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "sceneId", "generationId", "requestId", "status", "revision",
          "committedSequence", "rejection",
        ], path: "$")
    default: throw SceneWireError.invalidJSON
    }
    if let rejection = root["rejection"] as? [String: Any] {
      try keys(
        rejection, allowed: ["code", "message", "expectedRevision", "expectedSequence"],
        path: "$.rejection")
    }
    return try JSONDecoder().decode(ApplyReceipt.self, from: data)
  }

  private func rootObject(_ data: Data) throws -> [String: Any] {
    guard data.count <= Self.maximumMessageBytes else {
      throw SceneWireError.messageTooLarge(data.count)
    }
    guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw SceneWireError.invalidJSON
    }
    return value
  }

  private func inspectEnvelope(_ root: [String: Any], path: String) throws {
    guard let type = root["type"] as? String else { throw SceneWireError.invalidJSON }
    switch type {
    case "hello":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "sceneSchemaVersions", "geometrySemanticsVersions",
          "capabilities",
        ], path: path)
    case "generation.begin":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "requestId", "sceneId", "generationId", "intentEpoch",
          "initialBaseRevision", "scopeParentNodeId",
        ], path: path)
    case "generation.batch":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "requestId", "sceneId", "generationId", "intentEpoch",
          "sequence", "payloadHash", "operations",
        ], path: path)
      try inspectOperations(root["operations"], path: "$.operations")
    case "generation.finish":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "requestId", "sceneId", "generationId", "intentEpoch",
          "lastSequence",
        ], path: path)
    case "scene.patch":
      try keys(
        root,
        allowed: [
          "type", "protocolVersion", "requestId", "sceneId", "intentEpoch", "baseRevision",
          "payloadHash", "operations",
        ], path: path)
      try inspectOperations(root["operations"], path: "$.operations")
    default: throw SceneWireError.invalidJSON
    }
  }

  private func validateEnvelopeBounds(_ message: ClientMessage) throws {
    switch message {
    case .hello(let value):
      guard value.protocolVersion == 1, value.sceneSchemaVersions.contains(1),
        value.geometrySemanticsVersions.contains(1)
      else { throw SceneWireError.invalidValue(path: "$.protocolVersion") }
    case .generationBegin(let value):
      try requireID(value.requestId, "$.requestId")
      try requireID(value.sceneId, "$.sceneId")
      try requireID(value.generationId, "$.generationId")
      if let parent = value.scopeParentNodeId { try requireID(parent, "$.scopeParentNodeId") }
      try requireV1(value.protocolVersion, value.intentEpoch, value.initialBaseRevision)
    case .generationBatch(let value):
      try requireID(value.requestId, "$.requestId")
      try requireID(value.sceneId, "$.sceneId")
      try requireID(value.generationId, "$.generationId")
      try requireV1(value.protocolVersion, value.intentEpoch, value.sequence)
      guard value.sequence > 0, value.operations.count <= 128, isHash(value.payloadHash) else {
        throw SceneWireError.invalidValue(path: "$")
      }
    case .generationFinish(let value):
      try requireID(value.requestId, "$.requestId")
      try requireID(value.sceneId, "$.sceneId")
      try requireID(value.generationId, "$.generationId")
      try requireV1(value.protocolVersion, value.intentEpoch, value.lastSequence)
    case .scenePatch(let value):
      try requireID(value.requestId, "$.requestId")
      try requireID(value.sceneId, "$.sceneId")
      try requireV1(value.protocolVersion, value.intentEpoch, value.baseRevision)
      guard value.operations.count <= 128, isHash(value.payloadHash) else {
        throw SceneWireError.invalidValue(path: "$")
      }
    }
  }

  private func requireV1(_ protocolVersion: Int, _ values: UInt64...) throws {
    guard protocolVersion == 1,
      values.allSatisfy({ $0 <= SceneState.maximumWireInteger })
    else { throw SceneWireError.invalidValue(path: "$") }
  }

  private func requireID(_ value: String, _ path: String) throws {
    guard !value.isEmpty, value.utf8.count <= 128 else {
      throw SceneWireError.invalidValue(path: path)
    }
  }

  private func isHash(_ value: String) -> Bool {
    value.utf8.count == 64
      && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
  }

  private func inspectDocument(_ value: [String: Any], path: String) throws {
    try keys(
      value,
      allowed: [
        "schemaVersion", "geometrySemanticsVersion", "documentId", "geometryDefinitions",
        "materials", "nodes", "relationships",
      ], path: path)
    try inspectArray(
      value["geometryDefinitions"], path: "\(path).geometryDefinitions", inspectGeometry)
    try inspectArray(value["materials"], path: "\(path).materials", inspectMaterial)
    try inspectArray(value["nodes"], path: "\(path).nodes", inspectNode)
    try inspectArray(value["relationships"], path: "\(path).relationships", inspectRelationship)
  }

  private func inspectOperations(_ value: Any?, path: String) throws {
    guard let values = value as? [Any] else { return }
    for (index, raw) in values.enumerated() {
      guard let operation = raw as? [String: Any], let kind = operation["op"] as? String else {
        continue
      }
      let itemPath = "\(path)[\(index)]"
      switch kind {
      case "put.geometry":
        try keys(operation, allowed: ["op", "geometry"], path: itemPath)
        if let nested = operation["geometry"] as? [String: Any] {
          try inspectGeometry(nested, "\(itemPath).geometry")
        }
      case "put.material":
        try keys(operation, allowed: ["op", "material"], path: itemPath)
        if let nested = operation["material"] as? [String: Any] {
          try inspectMaterial(nested, "\(itemPath).material")
        }
      case "create.node":
        try keys(operation, allowed: ["op", "node"], path: itemPath)
        if let nested = operation["node"] as? [String: Any] {
          try inspectNode(nested, "\(itemPath).node")
        }
      case "remove.node": try keys(operation, allowed: ["op", "nodeId"], path: itemPath)
      case "set.transform":
        try keys(operation, allowed: ["op", "nodeId", "transform"], path: itemPath)
        if let nested = operation["transform"] as? [String: Any] {
          try inspectTransform(nested, "\(itemPath).transform")
        }
      case "set.geometry":
        try keys(operation, allowed: ["op", "nodeId", "geometryId"], path: itemPath)
      case "set.material":
        try keys(operation, allowed: ["op", "nodeId", "materialId"], path: itemPath)
      case "set.visibility":
        try keys(operation, allowed: ["op", "nodeId", "isVisible"], path: itemPath)
      case "put.relationship":
        try keys(operation, allowed: ["op", "relationship"], path: itemPath)
        if let nested = operation["relationship"] as? [String: Any] {
          try inspectRelationship(nested, "\(itemPath).relationship")
        }
      case "remove.relationship":
        try keys(operation, allowed: ["op", "relationshipId"], path: itemPath)
      default: continue
      }
    }
  }

  private func inspectGeometry(_ value: [String: Any], _ path: String) throws {
    try keys(value, allowed: ["geometryId", "contentHash", "recipe"], path: path)
    if let recipe = value["recipe"] as? [String: Any] {
      try inspectRecipe(recipe, "\(path).recipe")
    }
  }
  private func inspectRecipe(_ value: [String: Any], _ path: String) throws {
    guard let kind = value["kind"] as? String else { return }
    let allowed: Set<String>
    switch kind {
    case "box": allowed = ["kind", "size"]
    case "sphere": allowed = ["kind", "radius", "segments"]
    case "cylinder": allowed = ["kind", "radius", "height", "radialSegments"]
    case "cone": allowed = ["kind", "bottomRadius", "topRadius", "height", "radialSegments"]
    case "tube": allowed = ["kind", "points", "radius", "radialSegments"]
    case "arrow":
      allowed = [
        "kind", "start", "end", "shaftRadius", "headRadius", "headLength", "radialSegments",
      ]
    default: return
    }
    try keys(value, allowed: allowed, path: path)
  }
  private func inspectMaterial(_ value: [String: Any], _ path: String) throws {
    try keys(
      value, allowed: ["materialId", "baseColorLinear", "metallic", "roughness"], path: path)
  }
  private func inspectNode(_ value: [String: Any], _ path: String) throws {
    try keys(
      value,
      allowed: [
        "nodeId", "parentId", "geometryId", "materialId", "transform", "isVisible", "semantic",
        "provenance",
      ], path: path)
    if let nested = value["transform"] as? [String: Any] {
      try inspectTransform(nested, "\(path).transform")
    }
    if let nested = value["semantic"] as? [String: Any] {
      try keys(nested, allowed: ["name", "role", "description"], path: "\(path).semantic")
    }
    if let nested = value["provenance"] as? [String: Any] {
      try keys(
        nested, allowed: ["origin", "factualSupport", "sourceRefs"], path: "\(path).provenance")
    }
  }
  private func inspectTransform(_ value: [String: Any], _ path: String) throws {
    try keys(value, allowed: ["translation", "rotation", "scale"], path: path)
  }
  private func inspectRelationship(_ value: [String: Any], _ path: String) throws {
    try keys(
      value, allowed: ["relationshipId", "kind", "sourceNodeId", "targetNodeId", "description"],
      path: path)
  }

  private func inspectArray(
    _ value: Any?, path: String, _ inspection: ([String: Any], String) throws -> Void
  ) throws {
    guard let values = value as? [Any] else { return }
    for (index, raw) in values.enumerated() {
      if let object = raw as? [String: Any] { try inspection(object, "\(path)[\(index)]") }
    }
  }

  private func keys(_ object: [String: Any], allowed: Set<String>, path: String) throws {
    if let unknown = object.keys.first(where: { !allowed.contains($0) }) {
      throw SceneWireError.unknownProperty(path: path, property: unknown)
    }
  }
}
