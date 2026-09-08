import ARKit
import Foundation

struct SavedObject: Codable, Identifiable {
  var id: UUID
  var assembly: Assembly
  var home: [Float]
  var pose: [Float]
  var explosion: Float
  var hologram: Bool
  var inferred: Bool
  var extracted: Bool
}
struct SavedRoom: Codable, Identifiable {
  var version = 1
  var id: UUID
  var updated: Date
  var map: Data
  var objects: [SavedObject]
  var title: String { objects.first?.assembly.name ?? "Saved place" }
}
struct RoomStore {
  let directory: URL
  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("SavedRooms", isDirectory: true)
  }
  func rooms() throws -> [SavedRoom] {
    guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
    return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
      .filter { $0.pathExtension == "json" }
      .map { try JSONDecoder().decode(SavedRoom.self, from: Data(contentsOf: $0)) }
      .sorted { $0.updated > $1.updated }
  }
  func write(_ room: SavedRoom) throws {
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let data = try JSONEncoder().encode(room)
    try data.write(to: directory.appendingPathComponent(room.id.uuidString + ".json"), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
  }
  func map(_ room: SavedRoom) throws -> ARWorldMap {
    guard room.version == 1, let map = try NSKeyedUnarchiver.unarchivedObject(ofClass: ARWorldMap.self, from: room.map) else {
      throw CocoaError(.fileReadCorruptFile)
    }
    return map
  }
}
extension simd_float4x4 {
  var savedValues: [Float] { [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] } }
  init?(savedValues v: [Float]) {
    guard v.count == 16, v.allSatisfy(\.isFinite) else { return nil }
    self.init(columns: (SIMD4(v[0],v[1],v[2],v[3]), SIMD4(v[4],v[5],v[6],v[7]), SIMD4(v[8],v[9],v[10],v[11]), SIMD4(v[12],v[13],v[14],v[15])))
  }
}
