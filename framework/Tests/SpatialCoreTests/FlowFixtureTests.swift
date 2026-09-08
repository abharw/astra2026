import Foundation
import Testing

@testable import SpatialCore

private func flowFixture(_ path: String) throws -> Data {
  var root = URL(fileURLWithPath: #filePath)
  for _ in 0..<3 { root.deleteLastPathComponent() }
  return try Data(contentsOf: root.appending(path: "contract/fixtures/\(path)"))
}

@Test(arguments: ["flow_energy_document.json", "flow_rack_document.json"])
func sharedFlowDocumentsAreAccepted(filename: String) throws {
  let scene = try SceneWireDecoder().decodeDocument(from: flowFixture("accepted/\(filename)"))
  #expect(scene.geometryDefinitions.contains { if case .flow = $0.recipe { true } else { false } })
  #expect(try SceneWireDecoder().decodeDocument(from: JSONEncoder().encode(scene)) == scene)
}

@Test func everySharedGeometryHashVectorMatchesSwift() throws {
  struct Vector: Decodable {
    let geometrySemanticsVersion: Int
    let recipe: GeometryRecipe
    let expectedContentHash: String
  }
  struct Vectors: Decodable { let geometryVectors: [Vector] }
  let vectors = try JSONDecoder().decode(Vectors.self, from: flowFixture("hash-vectors.json"))
  for vector in vectors.geometryVectors {
    #expect(
      try canonicalContentHash(
        for: vector.recipe, geometrySemanticsVersion: vector.geometrySemanticsVersion)
        == vector.expectedContentHash)
  }
}

@Test func sharedFlowPatchHasCanonicalPayloadHash() throws {
  let message = try SceneWireDecoder().decodeMessage(from: flowFixture("accepted/flow_patch.json"))
  guard case .scenePatch(let patch) = message else {
    Issue.record("Expected flow patch fixture")
    return
  }
  #expect(patch.payloadHash == "74d6425e2190b04f913ce68235c2e008c7631e699c4c5d603d2ab02e693a7207")
  #expect(try canonicalPayloadHash(for: patch) == patch.payloadHash)
}

@Test func nodeLocalBoundsRemainSnapshotMetadata() throws {
  let bounds = NodeLocalBounds(nodeId: "part", minimum: Vec3(-1, -2, -3), maximum: Vec3(1, 2, 3))
  #expect(try JSONDecoder().decode(NodeLocalBounds.self, from: JSONEncoder().encode(bounds)) == bounds)
}
