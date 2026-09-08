import XCTest
@testable import SpatialAssembly
final class ReferenceGeometryTests: XCTestCase {
  func testOldAssembliesStillDecodeWithoutResearchFields() throws {
    let json = """
    {"name":"Old saved model","description":"","confidence":"low","bounds":[0,0,1,1],"sizeMeters":[1,1,1],"parts":[{"id":"p","name":"Part","evidence":"observed","description":"","explode":[0,0,1],"primitives":[{"kind":"box","position":[0,0,0],"size":[1,1,1],"rotation":[0,0,0],"color":[1,1,1]}]}]}
    """
    let model = try JSONDecoder().decode(Assembly.self, from: Data(json.utf8))
    XCTAssertNil(model.research)
    XCTAssertNil(model.parts[0].sourceIds)
    XCTAssertNoThrow(try model.validated())
  }
  func testCustomMeshRejectsOutOfRangeIndex() throws {
    let primitive = Primitive(kind:"mesh",position:[0,0,0],size:[1,1,1],rotation:[0,0,0],color:[1,1,1],vertices:[[0,0,0],[0.5,0,0],[0,0.5,0]],triangles:[0,1,3])
    let part = AssemblyPart(id:"p",name:"Part",evidence:"inferred",description:"",explode:[0,0,1],primitives:[primitive])
    let model = Assembly(name:"Mesh",description:"",confidence:"low",bounds:[0,0,1,1],sizeMeters:[1,1,1],parts:[part])
    XCTAssertThrowsError(try model.validated())
  }
}
