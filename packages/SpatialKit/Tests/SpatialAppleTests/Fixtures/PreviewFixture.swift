import SpatialCore

enum PreviewFixture {
    static func sceneState() throws -> SceneState {
        let chassisRecipe = GeometryRecipe.box(size: Vec3(0.44, 0.09, 0.6))
        let fanRecipe = GeometryRecipe.cylinder(radius: 0.055, height: 0.025, radialSegments: 24)
        let chassis = GeometryDefinition(
            geometryId: "fixture_chassis_geometry",
            contentHash: try canonicalContentHash(for: chassisRecipe, geometrySemanticsVersion: 1),
            recipe: chassisRecipe
        )
        let fan = GeometryDefinition(
            geometryId: "fixture_fan_geometry",
            contentHash: try canonicalContentHash(for: fanRecipe, geometrySemanticsVersion: 1),
            recipe: fanRecipe
        )
        let metal = SpatialCore.Material(
            materialId: "fixture_metal",
            baseColorLinear: [0.10, 0.12, 0.15, 1],
            metallic: 0.75,
            roughness: 0.4
        )
        let accent = SpatialCore.Material(
            materialId: "fixture_accent",
            baseColorLinear: [0.10, 0.42, 0.8, 1],
            metallic: 0.25,
            roughness: 0.32
        )
        let provenance = Provenance(origin: .authored, factualSupport: .illustrative)
        let document = SceneDocument(
            documentId: "document_preview_fixture",
            geometryDefinitions: [chassis, fan],
            materials: [metal, accent],
            nodes: [
                SceneNode(
                    nodeId: "fixture_chassis",
                    geometryId: chassis.geometryId,
                    materialId: metal.materialId,
                    transform: Transform3D(translation: Vec3(0, 0, -0.7)),
                    semantic: NodeSemantic(name: "Preview chassis", role: "enclosure"),
                    provenance: provenance
                ),
                SceneNode(
                    nodeId: "fixture_fan",
                    parentId: "fixture_chassis",
                    geometryId: fan.geometryId,
                    materialId: accent.materialId,
                    transform: Transform3D(
                        translation: Vec3(0, 0.07, 0),
                        rotation: Quaternion(0.7071067811865475, 0, 0, 0.7071067811865476)
                    ),
                    semantic: NodeSemantic(name: "Preview cooling fan", role: "fan"),
                    provenance: provenance
                ),
            ]
        )
        return try SceneState(document: document, sceneId: "scene_preview_fixture")
    }
}
