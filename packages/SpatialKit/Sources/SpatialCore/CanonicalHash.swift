import Foundation

public enum CanonicalHashError: Error, Sendable, Equatable {
  case nonFiniteNumber
  case valueTooLarge
}

public func canonicalPayloadHash(for batch: GenerationBatch) throws -> String {
  var writer = CanonicalWriter()
  try writer.header()
  try writer.string(batch.type)
  try writer.integer(batch.protocolVersion)
  try writer.string(batch.requestId)
  try writer.string(batch.sceneId)
  try writer.string(batch.generationId)
  writer.unsigned(batch.intentEpoch)
  writer.unsigned(batch.sequence)
  try writer.operations(batch.operations)
  return SHA256.hexDigest(writer.data)
}

public func canonicalPayloadHash(for patch: ScenePatch) throws -> String {
  var writer = CanonicalWriter()
  try writer.header()
  try writer.string(patch.type)
  try writer.integer(patch.protocolVersion)
  try writer.string(patch.requestId)
  try writer.string(patch.sceneId)
  writer.unsigned(patch.intentEpoch)
  writer.unsigned(patch.baseRevision)
  try writer.operations(patch.operations)
  return SHA256.hexDigest(writer.data)
}

public func canonicalContentHash(for recipe: GeometryRecipe, geometrySemanticsVersion: Int = 1)
  throws -> String
{
  var writer = CanonicalWriter()
  try writer.header("astra-geometry-v1")
  try writer.integer(geometrySemanticsVersion)
  try writer.recipe(recipe)
  return SHA256.hexDigest(writer.data)
}

private struct CanonicalWriter {
  var data = Data()

  mutating func header(_ value: String = "astra-request-v1") throws {
    data.append(contentsOf: value.utf8)
    data.append(0)
  }

  mutating func byte(_ value: UInt8) { data.append(value) }

  mutating func unsigned(_ value: UInt64) {
    for shift in stride(from: 56, through: 0, by: -8) {
      byte(UInt8((value >> UInt64(shift)) & 0xff))
    }
  }

  mutating func signed(_ value: Int64) { unsigned(UInt64(bitPattern: value)) }

  mutating func integer(_ value: Int) throws {
    guard let exact = Int64(exactly: value) else { throw CanonicalHashError.valueTooLarge }
    signed(exact)
  }

  mutating func count(_ value: Int) throws {
    guard let exact = UInt32(exactly: value) else { throw CanonicalHashError.valueTooLarge }
    for shift in stride(from: 24, through: 0, by: -8) {
      byte(UInt8((exact >> UInt32(shift)) & 0xff))
    }
  }

  mutating func string(_ value: String) throws {
    let bytes = Array(value.utf8)
    try count(bytes.count)
    data.append(contentsOf: bytes)
  }

  mutating func optionalString(_ value: String?) throws {
    if let value {
      byte(1)
      try string(value)
    } else {
      byte(0)
    }
  }

  mutating func double(_ value: Double) throws {
    guard value.isFinite else { throw CanonicalHashError.nonFiniteNumber }
    unsigned(value == 0 ? 0 : value.bitPattern)
  }

  mutating func vec3(_ value: Vec3) throws {
    try double(value.x)
    try double(value.y)
    try double(value.z)
  }
  mutating func quaternion(_ value: Quaternion) throws {
    try double(value.x)
    try double(value.y)
    try double(value.z)
    try double(value.w)
  }
  mutating func transform(_ value: Transform3D) throws {
    try vec3(value.translation)
    try quaternion(value.rotation)
    try vec3(value.scale)
  }

  mutating func recipe(_ value: GeometryRecipe) throws {
    switch value {
    case .box(let size):
      try string("box")
      try vec3(size)
    case .sphere(let radius, let segments):
      try string("sphere")
      try double(radius)
      try integer(segments)
    case .cylinder(let radius, let height, let radialSegments):
      try string("cylinder")
      try double(radius)
      try double(height)
      try integer(radialSegments)
    case .cone(let bottomRadius, let topRadius, let height, let radialSegments):
      try string("cone")
      try double(bottomRadius)
      try double(topRadius)
      try double(height)
      try integer(radialSegments)
    case .tube(let points, let radius, let radialSegments):
      try string("tube")
      try count(points.count)
      for point in points { try vec3(point) }
      try double(radius)
      try integer(radialSegments)
    case .arrow(
      let start, let end, let shaftRadius, let headRadius, let headLength, let radialSegments):
      try string("arrow")
      try vec3(start)
      try vec3(end)
      try double(shaftRadius)
      try double(headRadius)
      try double(headLength)
      try integer(radialSegments)
    }
  }

  mutating func geometry(_ value: GeometryDefinition) throws {
    try string(value.geometryId)
    try string(value.contentHash)
    try recipe(value.recipe)
  }

  mutating func material(_ value: Material) throws {
    try string(value.materialId)
    try count(value.baseColorLinear.count)
    for channel in value.baseColorLinear { try double(channel) }
    try double(value.metallic)
    try double(value.roughness)
  }

  mutating func semantic(_ value: NodeSemantic) throws {
    try string(value.name)
    try optionalString(value.role)
    try optionalString(value.description)
  }

  mutating func provenance(_ value: Provenance) throws {
    try string(value.origin.rawValue)
    try string(value.factualSupport.rawValue)
    try count(value.sourceRefs.count)
    for source in value.sourceRefs { try string(source) }
  }

  mutating func node(_ value: SceneNode) throws {
    try string(value.nodeId)
    try optionalString(value.parentId)
    try optionalString(value.geometryId)
    try optionalString(value.materialId)
    try transform(value.transform)
    byte(value.isVisible ? 1 : 0)
    try semantic(value.semantic)
    try provenance(value.provenance)
  }

  mutating func relationship(_ value: Relationship) throws {
    try string(value.relationshipId)
    try string(value.kind)
    try string(value.sourceNodeId)
    try string(value.targetNodeId)
    try optionalString(value.description)
  }

  mutating func operations(_ values: [SceneOperation]) throws {
    try count(values.count)
    for value in values {
      switch value {
      case .putGeometry(let geometry):
        try string("put.geometry")
        try self.geometry(geometry)
      case .putMaterial(let material):
        try string("put.material")
        try self.material(material)
      case .createNode(let node):
        try string("create.node")
        try self.node(node)
      case .removeNode(let nodeId):
        try string("remove.node")
        try string(nodeId)
      case .setTransform(let nodeId, let transform):
        try string("set.transform")
        try string(nodeId)
        try self.transform(transform)
      case .setGeometry(let nodeId, let geometryId):
        try string("set.geometry")
        try string(nodeId)
        try optionalString(geometryId)
      case .setMaterial(let nodeId, let materialId):
        try string("set.material")
        try string(nodeId)
        try optionalString(materialId)
      case .setVisibility(let nodeId, let isVisible):
        try string("set.visibility")
        try string(nodeId)
        byte(isVisible ? 1 : 0)
      case .putRelationship(let relationship):
        try string("put.relationship")
        try self.relationship(relationship)
      case .removeRelationship(let relationshipId):
        try string("remove.relationship")
        try string(relationshipId)
      }
    }
  }
}

private enum SHA256 {
  private static let initial: [UInt32] = [
    0x6a09_e667, 0xbb67_ae85, 0x3c6e_f372, 0xa54f_f53a,
    0x510e_527f, 0x9b05_688c, 0x1f83_d9ab, 0x5be0_cd19,
  ]

  private static let constants: [UInt32] = [
    0x428a_2f98, 0x7137_4491, 0xb5c0_fbcf, 0xe9b5_dba5, 0x3956_c25b, 0x59f1_11f1, 0x923f_82a4,
    0xab1c_5ed5,
    0xd807_aa98, 0x1283_5b01, 0x2431_85be, 0x550c_7dc3, 0x72be_5d74, 0x80de_b1fe, 0x9bdc_06a7,
    0xc19b_f174,
    0xe49b_69c1, 0xefbe_4786, 0x0fc1_9dc6, 0x240c_a1cc, 0x2de9_2c6f, 0x4a74_84aa, 0x5cb0_a9dc,
    0x76f9_88da,
    0x983e_5152, 0xa831_c66d, 0xb003_27c8, 0xbf59_7fc7, 0xc6e0_0bf3, 0xd5a7_9147, 0x06ca_6351,
    0x1429_2967,
    0x27b7_0a85, 0x2e1b_2138, 0x4d2c_6dfc, 0x5338_0d13, 0x650a_7354, 0x766a_0abb, 0x81c2_c92e,
    0x9272_2c85,
    0xa2bf_e8a1, 0xa81a_664b, 0xc24b_8b70, 0xc76c_51a3, 0xd192_e819, 0xd699_0624, 0xf40e_3585,
    0x106a_a070,
    0x19a4_c116, 0x1e37_6c08, 0x2748_774c, 0x34b0_bcb5, 0x391c_0cb3, 0x4ed8_aa4a, 0x5b9c_ca4f,
    0x682e_6ff3,
    0x748f_82ee, 0x78a5_636f, 0x84c8_7814, 0x8cc7_0208, 0x90be_fffa, 0xa450_6ceb, 0xbef9_a3f7,
    0xc671_78f2,
  ]

  static func hexDigest(_ input: Data) -> String {
    var bytes = Array(input)
    let bitLength = UInt64(bytes.count) * 8
    bytes.append(0x80)
    while bytes.count % 64 != 56 { bytes.append(0) }
    for shift in stride(from: 56, through: 0, by: -8) {
      bytes.append(UInt8((bitLength >> UInt64(shift)) & 0xff))
    }

    var hash = initial
    for offset in stride(from: 0, to: bytes.count, by: 64) {
      var words = Array(repeating: UInt32(0), count: 64)
      for index in 0..<16 {
        let start = offset + index * 4
        words[index] =
          UInt32(bytes[start]) << 24 | UInt32(bytes[start + 1]) << 16 | UInt32(bytes[start + 2])
          << 8 | UInt32(bytes[start + 3])
      }
      for index in 16..<64 {
        let x = words[index - 15]
        let y = words[index - 2]
        let s0 = rotate(x, 7) ^ rotate(x, 18) ^ (x >> 3)
        let s1 = rotate(y, 17) ^ rotate(y, 19) ^ (y >> 10)
        words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
      }
      var a = hash[0]
      var b = hash[1]
      var c = hash[2]
      var d = hash[3]
      var e = hash[4]
      var f = hash[5]
      var g = hash[6]
      var h = hash[7]
      for index in 0..<64 {
        let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
        let choice = (e & f) ^ ((~e) & g)
        let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
        let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
        let majority = (a & b) ^ (a & c) ^ (b & c)
        let temp2 = s0 &+ majority
        h = g
        g = f
        f = e
        e = d &+ temp1
        d = c
        c = b
        b = a
        a = temp1 &+ temp2
      }
      hash[0] &+= a
      hash[1] &+= b
      hash[2] &+= c
      hash[3] &+= d
      hash[4] &+= e
      hash[5] &+= f
      hash[6] &+= g
      hash[7] &+= h
    }
    return hash.map { String(format: "%08x", $0) }.joined()
  }

  private static func rotate(_ value: UInt32, _ amount: UInt32) -> UInt32 {
    (value >> amount) | (value << (32 - amount))
  }
}
