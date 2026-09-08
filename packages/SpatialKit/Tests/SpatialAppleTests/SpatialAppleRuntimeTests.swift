import Foundation
import RealityKit
@testable import SpatialApple
import SpatialCore
import Testing

private func explanationData(epoch: UInt64, text: String) throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "type": "session.explanation",
        "requestId": "explanation-request",
        "proposalRequestIds": [],
        "intentEpoch": epoch,
        "text": text,
    ])
}

@MainActor
@Test func linearMaterialComponentsConvertToSRGBDisplayValues() {
    #expect(MaterialCompiler.linearToSRGB(0) == 0)
    #expect(abs(MaterialCompiler.linearToSRGB(0.003_130_8) - 0.040_449_936) < 0.000_000_1)
    #expect(abs(MaterialCompiler.linearToSRGB(0.18) - 0.461_356_13) < 0.000_001)
    #expect(MaterialCompiler.linearToSRGB(1) == 1)
    #expect(MaterialCompiler.linearToSRGB(-0.5) == 0)
    #expect(MaterialCompiler.linearToSRGB(2) == 1)
}

@MainActor
@Test func acceptedSceneChangesInvalidateInstalledExplanation() async throws {
    var state = try PreviewFixture.sceneState()
    var setupPatch = ScenePatch(
        requestId: "setup-patch",
        sceneId: state.sceneId,
        intentEpoch: state.intentEpoch,
        baseRevision: state.revision,
        payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)]
    )
    setupPatch.payloadHash = try canonicalPayloadHash(for: setupPatch)
    _ = state.apply(.scenePatch(setupPatch))

    let controller = SceneController(initialState: state)
    await controller.receive(try explanationData(epoch: state.intentEpoch, text: "The fan is hidden."))
    #expect(controller.lastExplanation == "The fan is hidden.")

    controller.undo()
    #expect(controller.lastExplanation == nil)

    await controller.receive(try explanationData(
        epoch: controller.acceptedScene.intentEpoch,
        text: "The fixture is restored."
    ))
    #expect(controller.lastExplanation == "The fixture is restored.")

    try controller.loadScene(PreviewFixture.sceneState())
    #expect(controller.lastExplanation == nil)

    await controller.receive(try explanationData(
        epoch: controller.acceptedScene.intentEpoch,
        text: "The fixture is visible."
    ))
    var incomingPatch = ScenePatch(
        requestId: "incoming-patch",
        sceneId: controller.acceptedScene.sceneId,
        intentEpoch: controller.acceptedScene.intentEpoch,
        baseRevision: controller.acceptedScene.revision,
        payloadHash: "",
        operations: [.setVisibility(nodeId: "fixture_fan", isVisible: false)]
    )
    incomingPatch.payloadHash = try canonicalPayloadHash(for: incomingPatch)
    await controller.receive(try JSONEncoder().encode(ClientMessage.scenePatch(incomingPatch)))
    #expect(controller.lastExplanation == nil)
}

@MainActor
@Test func previewFixtureBuildsASelectableHierarchy() throws {
    let state = try PreviewFixture.sceneState()
    let renderer = SceneRenderer(initialState: state)
    try renderer.loadScene(state)

    let chassis = try #require(renderer.entity(for: "fixture_chassis"))
    let fan = try #require(renderer.entity(for: "fixture_fan"))
    #expect(fan.parent === chassis)
    #expect(chassis is ModelEntity)
    #expect(fan is ModelEntity)
}

@MainActor
@Test func transformOnlyUpdatePreservesNativeEntityIdentity() throws {
    let state = try PreviewFixture.sceneState()
    let renderer = SceneRenderer(initialState: state)
    try renderer.loadScene(state)
    let before = try #require(renderer.entity(for: "fixture_fan"))

    var updated = state.document
    let index = try #require(updated.nodes.firstIndex { $0.nodeId == "fixture_fan" })
    updated.nodes[index].transform.translation = Vec3(0.12, 0.07, 0)
    try renderer.loadScene(updated)

    let after = try #require(renderer.entity(for: "fixture_fan"))
    #expect(before === after)
    #expect(after.position.x == Float(0.12))
}

@MainActor
@Test func everyV1ProceduralRecipeBuildsNativeMesh() throws {
    let recipes: [GeometryRecipe] = [
        .box(size: Vec3(0.2, 0.1, 0.3)),
        .sphere(radius: 0.1, segments: 16),
        .cylinder(radius: 0.08, height: 0.2, radialSegments: 16),
        .cone(bottomRadius: 0.1, topRadius: 0.025, height: 0.2, radialSegments: 16),
        .tube(points: [Vec3(0, 0, 0), Vec3(0.1, 0.05, 0), Vec3(0.2, 0.05, 0.1)], radius: 0.01, radialSegments: 12),
        .arrow(start: Vec3(0, 0, 0), end: Vec3(0.2, 0.15, 0.1), shaftRadius: 0.01, headRadius: 0.025, headLength: 0.06, radialSegments: 12),
    ]
    let compiler = GeometryCompiler()

    for (index, recipe) in recipes.enumerated() {
        let definition = GeometryDefinition(
            geometryId: "geometry_\(index)",
            contentHash: try canonicalContentHash(for: recipe, geometrySemanticsVersion: 1),
            recipe: recipe
        )
        let resource = try compiler.resource(for: definition)
        #expect(resource.bounds.extents.x > 0)
        #expect(resource.bounds.extents.y > 0)
        #expect(resource.bounds.extents.z > 0)
    }
}
