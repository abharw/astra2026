import Foundation
import simd

struct Assembly: Codable {
  var name: String
  var description: String
  var confidence: String
  var bounds: [Float]
  var sizeMeters: [Float]
  var parts: [AssemblyPart]
  func validated() throws -> Assembly {
    guard parts.count > 0, parts.count <= 24, sizeMeters.count == 3,
      sizeMeters.allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 20 }), bounds.count == 4,
      bounds.allSatisfy({ $0.isFinite && (0...1).contains($0) }), bounds[2] > bounds[0],
      bounds[3] > bounds[1]
    else { throw AssemblyError.invalid }
    var ids = Set<String>()
    var total = 0
    for part in parts {
      guard ids.insert(part.id).inserted, ["observed", "inferred"].contains(part.evidence),
        part.explode.validVector(limit: 4), !part.primitives.isEmpty, part.primitives.count <= 8
      else { throw AssemblyError.invalid }
      for p in part.primitives {
        total += 1
        guard ["box", "sphere", "cylinder", "cone", "torus"].contains(p.kind),
          p.position.validVector(limit: 2), p.size.validVector(limit: 2),
          p.size.allSatisfy({ $0 > 0 }), p.rotation.validVector(limit: 360),
          p.color.validVector(limit: 1), p.color.allSatisfy({ $0 >= 0 })
        else { throw AssemblyError.invalid }
      }
    }
    guard total <= 120 else { throw AssemblyError.invalid }
    return self
  }
}
struct AssemblyPart: Codable, Identifiable {
  var id: String
  var name: String
  var evidence: String
  var description: String
  var explode: [Float]
  var primitives: [Primitive]
}
struct Primitive: Codable {
  var kind: String
  var position: [Float]
  var size: [Float]
  var rotation: [Float]
  var color: [Float]
}
enum AssemblyError: LocalizedError {
  case invalid
  var errorDescription: String? { "The generated geometry was invalid. Try a clearer view." }
}
extension Array where Element == Float {
  var vector: SIMD3<Float> { count == 3 ? SIMD3(self[0], self[1], self[2]) : .zero }
  func validVector(limit: Float) -> Bool {
    count == 3 && allSatisfy { $0.isFinite && abs($0) <= limit }
  }
}
extension simd_float4x4 {
  var translation: SIMD3<Float> {
    get { SIMD3(columns.3.x, columns.3.y, columns.3.z) }
    set { columns.3 = SIMD4(newValue, 1) }
  }
}
