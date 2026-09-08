import XCTest
import simd
@testable import SpatialAssembly

final class RoomStoreTests: XCTestCase {
  var folder: URL!
  override func setUpWithError() throws { folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
  override func tearDownWithError() throws { if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) } }
  func testRoomUpdateKeepsOtherPlacesAndAllObjectState() throws {
    let store = RoomStore(directory: folder)
    let spec = Assembly(name: "Test", description: "", confidence: "low", bounds: [0,0,1,1], sizeMeters: [1,1,1], parts: [])
    var pose = matrix_identity_float4x4
    pose.columns.3 = SIMD4(2,3,4,1)
    let object = SavedObject(id: UUID(), assembly: spec, home: matrix_identity_float4x4.savedValues, pose: pose.savedValues, explosion: 0.7, hologram: false, inferred: false, extracted: true)
    var first = SavedRoom(id: UUID(), updated: Date(timeIntervalSince1970: 1), map: Data([1]), objects: [object])
    let second = SavedRoom(id: UUID(), updated: Date(timeIntervalSince1970: 2), map: Data([2]), objects: [object, object])
    try store.write(first); try store.write(second)
    first.updated = Date(timeIntervalSince1970: 3)
    try store.write(first)
    let loaded = try store.rooms()
    XCTAssertEqual(loaded.count, 2)
    XCTAssertEqual(loaded[0].id, first.id)
    XCTAssertEqual(loaded[1].objects.count, 2)
    XCTAssertEqual(loaded[0].objects[0].pose, pose.savedValues)
    XCTAssertEqual(loaded[0].objects[0].explosion, 0.7)
    XCTAssertTrue(loaded[0].objects[0].extracted)
    XCTAssertFalse(loaded[0].objects[0].inferred)
    XCTAssertFalse(loaded[0].objects[0].hologram)
  }
  func testRejectsInvalidPose() {
    XCTAssertNil(simd_float4x4(savedValues: [0]))
    XCTAssertNil(simd_float4x4(savedValues: Array(repeating: Float.nan, count: 16)))
    XCTAssertEqual(simd_float4x4(savedValues: matrix_identity_float4x4.savedValues)?.savedValues, matrix_identity_float4x4.savedValues)
  }
  func testCorruptMapFailsInsteadOfRestoringIntoWrongCoordinates() {
    let room = SavedRoom(id: UUID(), updated: Date(), map: Data(), objects: [])
    XCTAssertThrowsError(try RoomStore(directory: folder).map(room))
  }
  func testEmptyLibrary() throws { XCTAssertTrue(try RoomStore(directory: folder).rooms().isEmpty) }
}
