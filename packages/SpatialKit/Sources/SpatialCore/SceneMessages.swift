import Foundation

public enum SceneCapability: String, Codable, Sendable, CaseIterable {
  case box = "box.v1"
  case sphere = "sphere.v1"
  case cylinder = "cylinder.v1"
  case cone = "cone.v1"
  case tube = "tube.v1"
  case arrow = "arrow.v1"
}

public struct Hello: Codable, Sendable, Equatable {
  public let type = "hello"
  public var protocolVersion: Int
  public var sceneSchemaVersions: [Int]
  public var geometrySemanticsVersions: [Int]
  public var capabilities: [SceneCapability]

  public init(
    protocolVersion: Int = 1,
    sceneSchemaVersions: [Int] = [1],
    geometrySemanticsVersions: [Int] = [1],
    capabilities: [SceneCapability] = SceneCapability.allCases
  ) {
    self.protocolVersion = protocolVersion
    self.sceneSchemaVersions = sceneSchemaVersions
    self.geometrySemanticsVersions = geometrySemanticsVersions
    self.capabilities = capabilities
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, sceneSchemaVersions, geometrySemanticsVersions, capabilities
  }
}

public struct GenerationBegin: Codable, Sendable, Equatable {
  public let type = "generation.begin"
  public var protocolVersion: Int
  public var requestId: String
  public var sceneId: String
  public var generationId: String
  public var intentEpoch: UInt64
  public var initialBaseRevision: UInt64
  public var scopeParentNodeId: String?

  public init(
    protocolVersion: Int = 1, requestId: String, sceneId: String, generationId: String,
    intentEpoch: UInt64, initialBaseRevision: UInt64, scopeParentNodeId: String? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.sceneId = sceneId
    self.generationId = generationId
    self.intentEpoch = intentEpoch
    self.initialBaseRevision = initialBaseRevision
    self.scopeParentNodeId = scopeParentNodeId
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, requestId, sceneId, generationId, intentEpoch, initialBaseRevision,
      scopeParentNodeId
  }
}

public struct GenerationBatch: Codable, Sendable, Equatable {
  public let type = "generation.batch"
  public var protocolVersion: Int
  public var requestId: String
  public var sceneId: String
  public var generationId: String
  public var intentEpoch: UInt64
  public var sequence: UInt64
  public var payloadHash: String
  public var operations: [SceneOperation]

  public init(
    protocolVersion: Int = 1, requestId: String, sceneId: String, generationId: String,
    intentEpoch: UInt64, sequence: UInt64, payloadHash: String, operations: [SceneOperation]
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.sceneId = sceneId
    self.generationId = generationId
    self.intentEpoch = intentEpoch
    self.sequence = sequence
    self.payloadHash = payloadHash
    self.operations = operations
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, requestId, sceneId, generationId, intentEpoch, sequence,
      payloadHash, operations
  }
}

public struct GenerationFinish: Codable, Sendable, Equatable {
  public let type = "generation.finish"
  public var protocolVersion: Int
  public var requestId: String
  public var sceneId: String
  public var generationId: String
  public var intentEpoch: UInt64
  public var lastSequence: UInt64

  public init(
    protocolVersion: Int = 1, requestId: String, sceneId: String, generationId: String,
    intentEpoch: UInt64, lastSequence: UInt64
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.sceneId = sceneId
    self.generationId = generationId
    self.intentEpoch = intentEpoch
    self.lastSequence = lastSequence
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, requestId, sceneId, generationId, intentEpoch, lastSequence
  }
}

public struct ScenePatch: Codable, Sendable, Equatable {
  public let type = "scene.patch"
  public var protocolVersion: Int
  public var requestId: String
  public var sceneId: String
  public var intentEpoch: UInt64
  public var baseRevision: UInt64
  public var payloadHash: String
  public var operations: [SceneOperation]

  public init(
    protocolVersion: Int = 1, requestId: String, sceneId: String, intentEpoch: UInt64,
    baseRevision: UInt64, payloadHash: String, operations: [SceneOperation]
  ) {
    self.protocolVersion = protocolVersion
    self.requestId = requestId
    self.sceneId = sceneId
    self.intentEpoch = intentEpoch
    self.baseRevision = baseRevision
    self.payloadHash = payloadHash
    self.operations = operations
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, requestId, sceneId, intentEpoch, baseRevision, payloadHash,
      operations
  }
}

public enum ClientMessage: Codable, Sendable, Equatable {
  case hello(Hello)
  case generationBegin(GenerationBegin)
  case generationBatch(GenerationBatch)
  case generationFinish(GenerationFinish)
  case scenePatch(ScenePatch)

  private enum CodingKeys: String, CodingKey { case type }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .type) {
    case "hello": self = .hello(try Hello(from: decoder))
    case "generation.begin": self = .generationBegin(try GenerationBegin(from: decoder))
    case "generation.batch": self = .generationBatch(try GenerationBatch(from: decoder))
    case "generation.finish": self = .generationFinish(try GenerationFinish(from: decoder))
    case "scene.patch": self = .scenePatch(try ScenePatch(from: decoder))
    case let type:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: values, debugDescription: "Unsupported message type \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .hello(let value): try value.encode(to: encoder)
    case .generationBegin(let value): try value.encode(to: encoder)
    case .generationBatch(let value): try value.encode(to: encoder)
    case .generationFinish(let value): try value.encode(to: encoder)
    case .scenePatch(let value): try value.encode(to: encoder)
    }
  }
}

public enum SceneOperation: Sendable, Equatable {
  case putGeometry(GeometryDefinition)
  case putMaterial(Material)
  case createNode(SceneNode)
  case removeNode(nodeId: String)
  case setTransform(nodeId: String, transform: Transform3D)
  case setGeometry(nodeId: String, geometryId: String?)
  case setMaterial(nodeId: String, materialId: String?)
  case setVisibility(nodeId: String, isVisible: Bool)
  case putRelationship(Relationship)
  case removeRelationship(relationshipId: String)
}

extension SceneOperation: Codable {
  private enum CodingKeys: String, CodingKey {
    case op, geometry, material, node, nodeId, transform, geometryId, materialId, isVisible,
      relationship, relationshipId
  }

  private enum Kind: String, Codable {
    case putGeometry = "put.geometry"
    case putMaterial = "put.material"
    case createNode = "create.node"
    case removeNode = "remove.node"
    case setTransform = "set.transform"
    case setGeometry = "set.geometry"
    case setMaterial = "set.material"
    case setVisibility = "set.visibility"
    case putRelationship = "put.relationship"
    case removeRelationship = "remove.relationship"
  }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .op) {
    case .putGeometry:
      self = .putGeometry(try values.decode(GeometryDefinition.self, forKey: .geometry))
    case .putMaterial: self = .putMaterial(try values.decode(Material.self, forKey: .material))
    case .createNode: self = .createNode(try values.decode(SceneNode.self, forKey: .node))
    case .removeNode: self = .removeNode(nodeId: try values.decode(String.self, forKey: .nodeId))
    case .setTransform:
      self = .setTransform(
        nodeId: try values.decode(String.self, forKey: .nodeId),
        transform: try values.decode(Transform3D.self, forKey: .transform))
    case .setGeometry:
      self = .setGeometry(
        nodeId: try values.decode(String.self, forKey: .nodeId),
        geometryId: try values.decodeIfPresent(String.self, forKey: .geometryId))
    case .setMaterial:
      self = .setMaterial(
        nodeId: try values.decode(String.self, forKey: .nodeId),
        materialId: try values.decodeIfPresent(String.self, forKey: .materialId))
    case .setVisibility:
      self = .setVisibility(
        nodeId: try values.decode(String.self, forKey: .nodeId),
        isVisible: try values.decode(Bool.self, forKey: .isVisible))
    case .putRelationship:
      self = .putRelationship(try values.decode(Relationship.self, forKey: .relationship))
    case .removeRelationship:
      self = .removeRelationship(
        relationshipId: try values.decode(String.self, forKey: .relationshipId))
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .putGeometry(let geometry):
      try values.encode(Kind.putGeometry, forKey: .op)
      try values.encode(geometry, forKey: .geometry)
    case .putMaterial(let material):
      try values.encode(Kind.putMaterial, forKey: .op)
      try values.encode(material, forKey: .material)
    case .createNode(let node):
      try values.encode(Kind.createNode, forKey: .op)
      try values.encode(node, forKey: .node)
    case .removeNode(let nodeId):
      try values.encode(Kind.removeNode, forKey: .op)
      try values.encode(nodeId, forKey: .nodeId)
    case .setTransform(let nodeId, let transform):
      try values.encode(Kind.setTransform, forKey: .op)
      try values.encode(nodeId, forKey: .nodeId)
      try values.encode(transform, forKey: .transform)
    case .setGeometry(let nodeId, let geometryId):
      try values.encode(Kind.setGeometry, forKey: .op)
      try values.encode(nodeId, forKey: .nodeId)
      try values.encode(geometryId, forKey: .geometryId)
    case .setMaterial(let nodeId, let materialId):
      try values.encode(Kind.setMaterial, forKey: .op)
      try values.encode(nodeId, forKey: .nodeId)
      try values.encode(materialId, forKey: .materialId)
    case .setVisibility(let nodeId, let isVisible):
      try values.encode(Kind.setVisibility, forKey: .op)
      try values.encode(nodeId, forKey: .nodeId)
      try values.encode(isVisible, forKey: .isVisible)
    case .putRelationship(let relationship):
      try values.encode(Kind.putRelationship, forKey: .op)
      try values.encode(relationship, forKey: .relationship)
    case .removeRelationship(let relationshipId):
      try values.encode(Kind.removeRelationship, forKey: .op)
      try values.encode(relationshipId, forKey: .relationshipId)
    }
  }
}

public enum SceneReceiptStatus: String, Codable, Sendable { case installed, rejected }
public enum GenerationReceiptStatus: String, Codable, Sendable {
  case accepted, completed, rejected
}

public struct Rejection: Codable, Sendable, Equatable {
  public var code: String
  public var message: String
  public var expectedRevision: UInt64?
  public var expectedSequence: UInt64?

  public init(
    code: String, message: String, expectedRevision: UInt64? = nil, expectedSequence: UInt64? = nil
  ) {
    self.code = code
    self.message = message
    self.expectedRevision = expectedRevision
    self.expectedSequence = expectedSequence
  }
}

public struct SceneReceipt: Codable, Sendable, Equatable {
  public let type = "scene.receipt"
  public var protocolVersion: Int
  public var sceneId: String
  public var generationId: String?
  public var requestId: String
  public var sequence: UInt64?
  public var status: SceneReceiptStatus
  public var revision: UInt64
  public var affectedNodeIds: [String]
  public var rejection: Rejection?

  public init(
    protocolVersion: Int = 1, sceneId: String, generationId: String? = nil, requestId: String,
    sequence: UInt64? = nil, status: SceneReceiptStatus, revision: UInt64,
    affectedNodeIds: [String] = [], rejection: Rejection? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.sceneId = sceneId
    self.generationId = generationId
    self.requestId = requestId
    self.sequence = sequence
    self.status = status
    self.revision = revision
    self.affectedNodeIds = affectedNodeIds
    self.rejection = rejection
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, sceneId, generationId, requestId, sequence, status, revision,
      affectedNodeIds, rejection
  }
}

public struct GenerationReceipt: Codable, Sendable, Equatable {
  public let type = "generation.receipt"
  public var protocolVersion: Int
  public var sceneId: String
  public var generationId: String
  public var requestId: String
  public var status: GenerationReceiptStatus
  public var revision: UInt64
  public var committedSequence: UInt64
  public var rejection: Rejection?

  public init(
    protocolVersion: Int = 1, sceneId: String, generationId: String, requestId: String,
    status: GenerationReceiptStatus, revision: UInt64, committedSequence: UInt64,
    rejection: Rejection? = nil
  ) {
    self.protocolVersion = protocolVersion
    self.sceneId = sceneId
    self.generationId = generationId
    self.requestId = requestId
    self.status = status
    self.revision = revision
    self.committedSequence = committedSequence
    self.rejection = rejection
  }

  private enum CodingKeys: String, CodingKey {
    case type, protocolVersion, sceneId, generationId, requestId, status, revision,
      committedSequence, rejection
  }
}

public enum ApplyReceipt: Codable, Sendable, Equatable {
  case scene(SceneReceipt)
  case generation(GenerationReceipt)

  private enum CodingKeys: String, CodingKey { case type }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(String.self, forKey: .type) {
    case "scene.receipt": self = .scene(try SceneReceipt(from: decoder))
    case "generation.receipt": self = .generation(try GenerationReceipt(from: decoder))
    case let type:
      throw DecodingError.dataCorruptedError(
        forKey: .type, in: values, debugDescription: "Unsupported receipt type \(type)")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    switch self {
    case .scene(let value): try value.encode(to: encoder)
    case .generation(let value): try value.encode(to: encoder)
    }
  }
}
