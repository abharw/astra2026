import Foundation

public struct Vec3: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var z: Double

  public init(_ x: Double, _ y: Double, _ z: Double) {
    self.x = x
    self.y = y
    self.z = z
  }

  public init(from decoder: any Decoder) throws {
    var values = try decoder.unkeyedContainer()
    x = try values.decode(Double.self)
    y = try values.decode(Double.self)
    z = try values.decode(Double.self)
    guard values.isAtEnd else {
      throw DecodingError.dataCorruptedError(
        in: values, debugDescription: "Vec3 requires exactly three numbers")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.unkeyedContainer()
    try values.encode(x)
    try values.encode(y)
    try values.encode(z)
  }
}

public struct Quaternion: Codable, Sendable, Equatable {
  public var x: Double
  public var y: Double
  public var z: Double
  public var w: Double

  public init(_ x: Double, _ y: Double, _ z: Double, _ w: Double) {
    self.x = x
    self.y = y
    self.z = z
    self.w = w
  }

  public static let identity = Quaternion(0, 0, 0, 1)

  public init(from decoder: any Decoder) throws {
    var values = try decoder.unkeyedContainer()
    x = try values.decode(Double.self)
    y = try values.decode(Double.self)
    z = try values.decode(Double.self)
    w = try values.decode(Double.self)
    guard values.isAtEnd else {
      throw DecodingError.dataCorruptedError(
        in: values, debugDescription: "Quaternion requires exactly four numbers")
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.unkeyedContainer()
    try values.encode(x)
    try values.encode(y)
    try values.encode(z)
    try values.encode(w)
  }
}

public struct Transform3D: Codable, Sendable, Equatable {
  public var translation: Vec3
  public var rotation: Quaternion
  public var scale: Vec3

  public init(
    translation: Vec3 = Vec3(0, 0, 0),
    rotation: Quaternion = .identity,
    scale: Vec3 = Vec3(1, 1, 1)
  ) {
    self.translation = translation
    self.rotation = rotation
    self.scale = scale
  }
}

public enum GeometryRecipe: Sendable, Equatable {
  case box(size: Vec3)
  case sphere(radius: Double, segments: Int)
  case cylinder(radius: Double, height: Double, radialSegments: Int)
  case cone(bottomRadius: Double, topRadius: Double, height: Double, radialSegments: Int)
  case tube(points: [Vec3], radius: Double, radialSegments: Int)
  case arrow(
    start: Vec3, end: Vec3, shaftRadius: Double, headRadius: Double, headLength: Double,
    radialSegments: Int)
}

extension GeometryRecipe: Codable {
  private enum CodingKeys: String, CodingKey {
    case kind, size, radius, segments, height, radialSegments
    case bottomRadius, topRadius, points, start, end, shaftRadius, headRadius, headLength
  }

  private enum Kind: String, Codable { case box, sphere, cylinder, cone, tube, arrow }

  public init(from decoder: any Decoder) throws {
    let values = try decoder.container(keyedBy: CodingKeys.self)
    switch try values.decode(Kind.self, forKey: .kind) {
    case .box:
      self = .box(size: try values.decode(Vec3.self, forKey: .size))
    case .sphere:
      self = .sphere(
        radius: try values.decode(Double.self, forKey: .radius),
        segments: try values.decode(Int.self, forKey: .segments)
      )
    case .cylinder:
      self = .cylinder(
        radius: try values.decode(Double.self, forKey: .radius),
        height: try values.decode(Double.self, forKey: .height),
        radialSegments: try values.decode(Int.self, forKey: .radialSegments)
      )
    case .cone:
      self = .cone(
        bottomRadius: try values.decode(Double.self, forKey: .bottomRadius),
        topRadius: try values.decode(Double.self, forKey: .topRadius),
        height: try values.decode(Double.self, forKey: .height),
        radialSegments: try values.decode(Int.self, forKey: .radialSegments)
      )
    case .tube:
      self = .tube(
        points: try values.decode([Vec3].self, forKey: .points),
        radius: try values.decode(Double.self, forKey: .radius),
        radialSegments: try values.decode(Int.self, forKey: .radialSegments)
      )
    case .arrow:
      self = .arrow(
        start: try values.decode(Vec3.self, forKey: .start),
        end: try values.decode(Vec3.self, forKey: .end),
        shaftRadius: try values.decode(Double.self, forKey: .shaftRadius),
        headRadius: try values.decode(Double.self, forKey: .headRadius),
        headLength: try values.decode(Double.self, forKey: .headLength),
        radialSegments: try values.decode(Int.self, forKey: .radialSegments)
      )
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var values = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .box(let size):
      try values.encode(Kind.box, forKey: .kind)
      try values.encode(size, forKey: .size)
    case .sphere(let radius, let segments):
      try values.encode(Kind.sphere, forKey: .kind)
      try values.encode(radius, forKey: .radius)
      try values.encode(segments, forKey: .segments)
    case .cylinder(let radius, let height, let radialSegments):
      try values.encode(Kind.cylinder, forKey: .kind)
      try values.encode(radius, forKey: .radius)
      try values.encode(height, forKey: .height)
      try values.encode(radialSegments, forKey: .radialSegments)
    case .cone(let bottomRadius, let topRadius, let height, let radialSegments):
      try values.encode(Kind.cone, forKey: .kind)
      try values.encode(bottomRadius, forKey: .bottomRadius)
      try values.encode(topRadius, forKey: .topRadius)
      try values.encode(height, forKey: .height)
      try values.encode(radialSegments, forKey: .radialSegments)
    case .tube(let points, let radius, let radialSegments):
      try values.encode(Kind.tube, forKey: .kind)
      try values.encode(points, forKey: .points)
      try values.encode(radius, forKey: .radius)
      try values.encode(radialSegments, forKey: .radialSegments)
    case .arrow(
      let start, let end, let shaftRadius, let headRadius, let headLength, let radialSegments):
      try values.encode(Kind.arrow, forKey: .kind)
      try values.encode(start, forKey: .start)
      try values.encode(end, forKey: .end)
      try values.encode(shaftRadius, forKey: .shaftRadius)
      try values.encode(headRadius, forKey: .headRadius)
      try values.encode(headLength, forKey: .headLength)
      try values.encode(radialSegments, forKey: .radialSegments)
    }
  }
}

public struct GeometryDefinition: Codable, Sendable, Equatable {
  public var geometryId: String
  public var contentHash: String
  public var recipe: GeometryRecipe

  public init(geometryId: String, contentHash: String, recipe: GeometryRecipe) {
    self.geometryId = geometryId
    self.contentHash = contentHash
    self.recipe = recipe
  }
}

public struct Material: Codable, Sendable, Equatable {
  public var materialId: String
  public var baseColorLinear: [Double]
  public var metallic: Double
  public var roughness: Double

  public init(materialId: String, baseColorLinear: [Double], metallic: Double, roughness: Double) {
    self.materialId = materialId
    self.baseColorLinear = baseColorLinear
    self.metallic = metallic
    self.roughness = roughness
  }
}

public struct NodeSemantic: Codable, Sendable, Equatable {
  public var name: String
  public var role: String?
  public var description: String?

  public init(name: String, role: String? = nil, description: String? = nil) {
    self.name = name
    self.role = role
    self.description = description
  }
}

public enum ProvenanceOrigin: String, Codable, Sendable { case authored, generated, imported }
public enum FactualSupport: String, Codable, Sendable { case illustrative, referenceBased }

public struct Provenance: Codable, Sendable, Equatable {
  public var origin: ProvenanceOrigin
  public var factualSupport: FactualSupport
  public var sourceRefs: [String]

  public init(origin: ProvenanceOrigin, factualSupport: FactualSupport, sourceRefs: [String] = []) {
    self.origin = origin
    self.factualSupport = factualSupport
    self.sourceRefs = sourceRefs
  }
}

public struct SceneNode: Codable, Sendable, Equatable {
  public var nodeId: String
  public var parentId: String?
  public var geometryId: String?
  public var materialId: String?
  public var transform: Transform3D
  public var isVisible: Bool
  public var semantic: NodeSemantic
  public var provenance: Provenance

  public init(
    nodeId: String,
    parentId: String? = nil,
    geometryId: String? = nil,
    materialId: String? = nil,
    transform: Transform3D = Transform3D(),
    isVisible: Bool = true,
    semantic: NodeSemantic,
    provenance: Provenance
  ) {
    self.nodeId = nodeId
    self.parentId = parentId
    self.geometryId = geometryId
    self.materialId = materialId
    self.transform = transform
    self.isVisible = isVisible
    self.semantic = semantic
    self.provenance = provenance
  }
}

public struct Relationship: Codable, Sendable, Equatable {
  public var relationshipId: String
  public var kind: String
  public var sourceNodeId: String
  public var targetNodeId: String
  public var description: String?

  public init(
    relationshipId: String, kind: String, sourceNodeId: String, targetNodeId: String,
    description: String? = nil
  ) {
    self.relationshipId = relationshipId
    self.kind = kind
    self.sourceNodeId = sourceNodeId
    self.targetNodeId = targetNodeId
    self.description = description
  }
}

public struct SceneDocument: Codable, Sendable, Equatable {
  public var schemaVersion: Int
  public var geometrySemanticsVersion: Int
  public var documentId: String
  public var geometryDefinitions: [GeometryDefinition]
  public var materials: [Material]
  public var nodes: [SceneNode]
  public var relationships: [Relationship]

  public init(
    schemaVersion: Int = 1,
    geometrySemanticsVersion: Int = 1,
    documentId: String,
    geometryDefinitions: [GeometryDefinition] = [],
    materials: [Material] = [],
    nodes: [SceneNode] = [],
    relationships: [Relationship] = []
  ) {
    self.schemaVersion = schemaVersion
    self.geometrySemanticsVersion = geometrySemanticsVersion
    self.documentId = documentId
    self.geometryDefinitions = geometryDefinitions
    self.materials = materials
    self.nodes = nodes
    self.relationships = relationships
  }
}
