import Testing

@testable import SpatialCore

@Test func emptyDocumentIsValid() throws {
  let document = SceneDocument(documentId: "document_test")
  let state = try SceneState(document: document, sceneId: "scene_test")
  #expect(state.revision == 0)
}
