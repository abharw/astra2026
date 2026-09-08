import Foundation
import RealityKit
import SpatialCore
@testable import SpatialApple
import Testing
import simd

@MainActor
struct FlowRendererTests {
    @Test("Candidate bindings use full hierarchy matrices before native installation")
    func transformedBindings() throws {
        var document = try fixture()
        let renderer = SceneRenderer()
        try renderer.loadScene(document)
        let oldSource = try #require(renderer.entity(for: "source"))
        let oldTransform = oldSource.transform
        let index = try #require(document.nodes.firstIndex { $0.nodeId == "source" })
        document.nodes[index].transform.translation = Vec3(0.22, 0.11, -0.08)
        document.nodes[index].transform.rotation = Quaternion(0, sin(0.3), 0, cos(0.3))
        let prepared = try renderer.prepareScene(document)
        #expect(oldSource.transform == oldTransform)
        let path = try #require(prepared.flows.byNodeID["flow"]?.shape.path)
        renderer.installPreparedScene(document, prepared: prepared)
        let source = try #require(renderer.entity(for: "source"))
        let target = try #require(renderer.entity(for: "target"))
        let annotation = try #require(renderer.entity(for: "flow"))
        let start = source.convert(position: [0.025, 0.012, 0], to: annotation)
        let end = target.convert(position: [-0.025, 0, 0], to: annotation)
        #expect(simd_distance(SIMD3<Float>(try #require(path.points.first)), start) < 0.00001)
        #expect(simd_distance(SIMD3<Float>(try #require(path.points.last)), end) < 0.00001)
        #expect(renderer.entity(for: "source") === oldSource)
        #expect(renderer.flowMetrics.meshRebuildCount == 2)
        try renderer.loadScene(document)
        #expect(renderer.flowMetrics.meshRebuildCount == 2)
    }

    @Test("Reversal uses the same annotation identity and swaps the bound path")
    func reversalAndPruning() throws {
        var document = try fixture()
        let renderer = SceneRenderer()
        try renderer.loadScene(document)
        let first = try #require(renderer.prepareScene(document).flows.byNodeID["flow"]?.shape.path)
        let geometryIndex = try #require(document.geometryDefinitions.firstIndex { $0.geometryId == "flow.geometry" })
        guard case .flow(var flow) = document.geometryDefinitions[geometryIndex].recipe else { Issue.record("Missing flow"); return }
        flow.direction = .reverse
        let recipe = GeometryRecipe.flow(flow)
        document.geometryDefinitions[geometryIndex] = GeometryDefinition(geometryId: "flow.geometry.reversed", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
        let nodeIndex = try #require(document.nodes.firstIndex { $0.nodeId == "flow" })
        document.nodes[nodeIndex].geometryId = "flow.geometry.reversed"
        let prepared = try renderer.prepareScene(document)
        let reversed = try #require(prepared.flows.byNodeID["flow"]?.shape.path)
        #expect(simd_distance(try #require(first.points.first), try #require(reversed.points.last)) < 1e-10)
        #expect(simd_distance(try #require(first.points.last), try #require(reversed.points.first)) < 1e-10)
        renderer.installPreparedScene(document, prepared: prepared)
        #expect(renderer.flowMetrics.flowCount == 1)
        #expect(renderer.flowMetrics.markerCount == 4)
        document.nodes.removeAll { $0.nodeId == "flow" }
        // An unused flow definition may still reference previous node identities.
        document.nodes.removeAll { $0.nodeId == "source" }
        try renderer.loadScene(document)
        #expect(renderer.flowMetrics.flowCount == 0)
        #expect(renderer.flowMetrics.meshCount == 0)
        #expect(renderer.flowMetrics.markerCount == 0)
    }

    @Test("Coincident bound points suppress only visuals and retain the flow node")
    func coincidentEndpoints() throws {
        var document = try fixture()
        let geometryIndex = try #require(document.geometryDefinitions.firstIndex { $0.geometryId == "flow.geometry" })
        let sourceIndex = try #require(document.nodes.firstIndex { $0.nodeId == "source" })
        let targetIndex = try #require(document.nodes.firstIndex { $0.nodeId == "target" })
        document.nodes[targetIndex].transform = document.nodes[sourceIndex].transform
        let recipe = GeometryRecipe.flow(FlowRecipe(source: .init(nodeId: "source", localPoint: Vec3(0, 0, 0)),
            target: .init(nodeId: "target", localPoint: Vec3(0, 0, 0)), routePoints: [Vec3(1, 1, 1)], label: "Collapsed flow"))
        document.geometryDefinitions[geometryIndex] = .init(geometryId: "flow.geometry", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
        try SceneValidator().validate(document)
        let renderer = SceneRenderer()
        try renderer.loadScene(document)
        let entity = try #require(renderer.entity(for: "flow"))
        #expect(entity.children.isEmpty)
        #expect(renderer.flowMetrics.flowCount == 1)
        #expect(renderer.flowMetrics.meshCount == 0)
        #expect(renderer.flowMetrics.markerCount == 0)
    }

    @Test("Bounds include hidden structural descendants and exclude flow labels and markers")
    func structuralBounds() throws {
        var document = try fixture()
        let targetIndex = try #require(document.nodes.firstIndex { $0.nodeId == "target" })
        document.nodes[targetIndex].isVisible = false
        let renderer = SceneRenderer()
        try renderer.loadScene(document)
        let original = renderer.nodeLocalBounds()
        #expect(original.contains { $0.nodeId == "assembly" })
        #expect(original.contains { $0.nodeId == "target" })
        #expect(!original.contains { $0.nodeId == "flow" })
        #expect(renderer.nodeLocalBounds(prioritizing: ["target"], maximumCount: 1).first?.nodeId == "target")
        #expect(renderer.nodeLocalBounds(maximumCount: 0).isEmpty)
        renderer.setSelection("source")
        renderer.setFlowAnimationEnabled(false)
        try renderer.loadScene(document)
        #expect(renderer.nodeLocalBounds() == original)
        document.nodes.removeAll { $0.nodeId == "flow" }
        try renderer.loadScene(document)
        #expect(renderer.nodeLocalBounds() == original)
        let sourceIndex = try #require(document.nodes.firstIndex { $0.nodeId == "source" })
        document.nodes[sourceIndex].transform.translation.x += 0.5
        try renderer.loadScene(document)
        #expect(renderer.nodeLocalBounds().first { $0.nodeId == "source" } == original.first { $0.nodeId == "source" })
        #expect(renderer.nodeLocalBounds().first { $0.nodeId == "assembly" } != original.first { $0.nodeId == "assembly" })
    }

    @Test("Animation changes only marker transforms; Reduce Motion leaves static annotation readable")
    func markerMotionAndMetrics() throws {
        let document = try fixture()
        let root = Entity()
        let flowRenderer = FlowRenderer()
        let prepared = try flowRenderer.prepare(document)
        flowRenderer.install(prepared, entities: ["flow": root])
        let marker = try #require(root.children.first { $0.name == "astra.flow.marker" })
        let body = try #require(root.children.first { $0.name == "astra.flow.body" })
        let originalPosition = marker.position
        flowRenderer.setMetricsEnabled(true)
        flowRenderer.resetMetrics()
        for _ in 0..<360 { flowRenderer.update(deltaTime: 1.0 / 60) }
        #expect(flowRenderer.metrics.sampleCount == 300)
        #expect(flowRenderer.metrics.updateCount == 360)
        #expect(flowRenderer.metrics.meshRebuildCount == 0)
        #expect(root.children.contains { $0 === body })
        #expect(marker.position != originalPosition)
        flowRenderer.setAnimationEnabled(false)
        let paused = marker.position
        flowRenderer.update(deltaTime: 1)
        #expect(marker.position == paused)
        #expect(root.children.filter { $0.name == "astra.flow.marker" }.allSatisfy { !$0.isEnabled })
        #expect(root.children.contains { $0.name == "astra.flow.label" && $0.isEnabled })
        #expect(flowRenderer.metrics.meanFrameIntervalMs > 0)
        #expect(flowRenderer.metrics.maximumMarkerUpdateMs.isFinite)
    }

    @Test("Unrepresentable cumulative native transforms reject without growing accepted caches")
    func rejectedCandidateCache() throws {
        let renderer = SceneRenderer()
        let original = try fixture()
        try renderer.loadScene(original)
        let before = renderer.flowMetrics
        for index in 0..<8 {
            var candidate = original
            let assembly = try #require(candidate.nodes.firstIndex { $0.nodeId == "assembly" })
            candidate.nodes[assembly].transform.scale = Vec3(1e-30, 1e-30, 1e-30)
            let source = try #require(candidate.nodes.firstIndex { $0.nodeId == "source" })
            candidate.nodes[source].transform.scale = Vec3(1e-30, 1e-30, 1e-30)
            let geometryIndex = try #require(candidate.geometryDefinitions.firstIndex { $0.geometryId == "flow.geometry" })
            guard case .flow(var flow) = candidate.geometryDefinitions[geometryIndex].recipe else { return }
            flow.label = "Rejected \(index)"
            let recipe = GeometryRecipe.flow(flow)
            candidate.geometryDefinitions[geometryIndex] = .init(geometryId: "flow.geometry", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
            #expect(throws: FlowPreparationError.self) { try renderer.loadScene(candidate) }
        }
        #expect(renderer.document == original)
        #expect(renderer.flowMetrics.meshCount == before.meshCount)
        #expect(renderer.flowMetrics.vertexCount == before.vertexCount)
    }

    @Test("Nonuniform annotation scale preserves the physical marker speed")
    func physicalMarkerSpeed() throws {
        var document = try fixture()
        let index = try #require(document.geometryDefinitions.firstIndex { $0.geometryId == "flow.geometry" })
        guard case .flow(var recipe) = document.geometryDefinitions[index].recipe else { return }
        recipe.routePoints = []
        document.geometryDefinitions[index].recipe = .flow(recipe)
        document.geometryDefinitions[index].contentHash = try canonicalContentHash(for: .flow(recipe))
        let root = Entity()
        root.transform = Transform(scale: [0.9, 1.1, 1.2], rotation: simd_quatf(angle: 0.3, axis: [0, 1, 0]), translation: [-0.02, 0.05, -0.04])
        let renderer = FlowRenderer()
        renderer.install(try renderer.prepare(document), entities: ["flow": root])
        let marker = try #require(root.children.first { $0.name == "astra.flow.marker" })
        let before = marker.position(relativeTo: nil)
        renderer.update(deltaTime: 0.1)
        let moved = simd_distance(before, marker.position(relativeTo: nil))
        #expect(abs(moved - 0.012) < 0.000001)
    }

    @Test("Whitespace labels allocate no invalid text mesh or billboard")
    func whitespaceLabel() throws {
        var document = try fixture()
        let index = try #require(document.geometryDefinitions.firstIndex { $0.geometryId == "flow.geometry" })
        guard case .flow(var recipe) = document.geometryDefinitions[index].recipe else { return }
        recipe.label = "  \n  "
        document.geometryDefinitions[index].recipe = .flow(recipe)
        document.geometryDefinitions[index].contentHash = try canonicalContentHash(for: .flow(recipe))
        let renderer = SceneRenderer()
        let prepared = try renderer.prepareScene(document)
        #expect(prepared.flows.labels.isEmpty)
        #expect(prepared.flows.byNodeID["flow"]?.label == nil)
        renderer.installPreparedScene(document, prepared: prepared)
        #expect(renderer.flowMetrics.meshCount == 2)
    }

    @Test("Readable physical labels share a padded backing mesh and release it with the final label")
    func labelBackingAndCache() throws {
        var document = try fixture()
        var duplicate = try #require(document.nodes.first { $0.nodeId == "flow" })
        duplicate.nodeId = "flow.second"
        duplicate.transform.translation.x += 0.25
        document.nodes.append(duplicate)
        let renderer = SceneRenderer()
        let prepared = try renderer.prepareScene(document)
        renderer.installPreparedScene(document, prepared: prepared)
        let background = try #require(prepared.flows.labelBackground)
        #expect(background.vertexCount == 4)
        #expect(background.triangleCount == 2)
        #expect(prepared.flows.labels.count == 1)
        let expectedMeshes = prepared.flows.shapes.values.compactMap(\.mesh).count + 3
        #expect(renderer.flowMetrics.meshCount == expectedMeshes)
        let contentRoot = try #require(renderer.entity(for: "flow")?.parent)
        let labels = contentRoot.children.filter { $0.name == "astra.flow.label" }
        #expect(labels.count == 2)
        for anchor in labels {
            #expect(anchor.components[BillboardComponent.self] != nil)
            #expect(anchor.scale == SIMD3<Float>(repeating: 0.035))
            let text = try #require(anchor.children.first { $0.name == "astra.flow.label.text" } as? ModelEntity)
            let backing = try #require(anchor.children.first { $0.name == "astra.flow.label.background" } as? ModelEntity)
            #expect(backing.model?.mesh === background.resource)
            let textBounds = text.visualBounds(relativeTo: anchor)
            let backingBounds = backing.visualBounds(relativeTo: anchor)
            #expect(backingBounds.min.x < textBounds.min.x && backingBounds.max.x > textBounds.max.x)
            #expect(backingBounds.min.y < textBounds.min.y && backingBounds.max.y > textBounds.max.y)
            #expect(backingBounds.max.z < textBounds.min.z)
            #expect(abs(backingBounds.center.x) < 0.00001 && abs(backingBounds.center.y) < 0.00001)
            // The font grew from 16 to 35 mm per unit, outside the annotation's
            // nonuniform transform. This fixture's real glyph height exceeds 2 cm.
            #expect(text.visualBounds(relativeTo: contentRoot).extents.y > 0.02)
        }
        for part in background.resource.contents.models.flatMap({ $0.parts }) {
            let positions = Array(part.positions)
            let indices = Array(try #require(part.triangleIndices))
            for index in stride(from: 0, to: indices.count, by: 3) {
                let a = positions[Int(indices[index])]
                let b = positions[Int(indices[index + 1])]
                let c = positions[Int(indices[index + 2])]
                #expect(simd_cross(b - a, c - a).z > 0)
            }
        }
        let repeated = try renderer.prepareScene(document)
        #expect(repeated.flows.labelBackground?.resource === background.resource)
        #expect(repeated.flows.labels["Energy transfer"]?.resource === prepared.flows.labels["Energy transfer"]?.resource)
        renderer.installPreparedScene(document, prepared: repeated)
        #expect(renderer.flowMetrics.meshCount == expectedMeshes)
        #expect(contentRoot.children.filter { $0.name == "astra.flow.label" }.count == 2)
        document.nodes.removeAll { $0.nodeId == "flow" }
        try renderer.loadScene(document)
        #expect(try renderer.prepareScene(document).flows.labelBackground?.resource === background.resource)
        document.nodes.removeAll { $0.nodeId == "flow.second" }
        try renderer.loadScene(document)
        #expect(renderer.flowMetrics.meshCount == 0)
        #expect(renderer.flowMetrics.vertexCount == 0)
        #expect(renderer.flowMetrics.triangleCount == 0)
        #expect(contentRoot.children.allSatisfy { $0.name != "astra.flow.label" })
        #expect(try renderer.prepareScene(document).flows.labelBackground == nil)
    }

    private func fixture() throws -> SceneDocument {
        let box = GeometryRecipe.box(size: Vec3(0.05, 0.04, 0.06))
        let flow = GeometryRecipe.flow(FlowRecipe(source: .init(nodeId: "source", localPoint: Vec3(0.025, 0.012, 0)),
            target: .init(nodeId: "target", localPoint: Vec3(-0.025, 0, 0)),
            routePoints: [Vec3(0.05, 0.1, -0.05)], label: "Energy transfer"))
        let provenance = Provenance(origin: .authored, factualSupport: .illustrative)
        func node(_ id: String, parent: String? = nil, geometry: String? = nil, transform: Transform3D = .init()) -> SceneNode {
            SceneNode(nodeId: id, parentId: parent, geometryId: geometry, transform: transform,
                semantic: .init(name: id), provenance: provenance)
        }
        return SceneDocument(documentId: "flow.native.fixture", geometryDefinitions: [
            .init(geometryId: "box", contentHash: try canonicalContentHash(for: box), recipe: box),
            .init(geometryId: "flow.geometry", contentHash: try canonicalContentHash(for: flow), recipe: flow)
        ], nodes: [
            node("assembly", transform: .init(translation: Vec3(0.3, -0.1, 0.2), rotation: Quaternion(0, 0, sin(0.25), cos(0.25)), scale: Vec3(1.3, 0.7, 1.1))),
            node("source", parent: "assembly", geometry: "box", transform: .init(translation: Vec3(-0.08, 0.02, 0), rotation: Quaternion(sin(0.2), 0, 0, cos(0.2)), scale: Vec3(0.8, 1.2, 0.9))),
            node("target", parent: "assembly", geometry: "box", transform: .init(translation: Vec3(0.12, 0.1, 0.03))),
            node("flow", geometry: "flow.geometry", transform: .init(translation: Vec3(-0.02, 0.05, -0.04), rotation: Quaternion(0, sin(0.15), 0, cos(0.15)), scale: Vec3(0.9, 1.1, 1.2)))
        ])
    }
}
