import CoreGraphics
import RealityKit
@testable import SpatialApple
import SpatialCore
import Testing
import simd

struct PreviewFramingTests {
    @Test("Preview includes every corner at small, large, tall and wide physical sizes",
          arguments: [SIMD3<Float>(0.001, 0.001, 0.001), SIMD3<Float>(100, 80, 60),
                      SIMD3<Float>(0.6, 2.21, 1.067), SIMD3<Float>(12, 0.05, 0.3)],
          [CGSize(width: 393, height: 852), CGSize(width: 852, height: 393), CGSize(width: 1024, height: 1366)])
    func fitsAllCorners(size: SIMD3<Float>, viewport: CGSize) throws {
        let center = SIMD3<Float>(2, 3, -4)
        let bounds = BoundingBox(min: center - size / 2, max: center + size / 2)
        let frame = try #require(PreviewCameraFrame.fitting(bounds, viewport: viewport))
        let direction = simd_normalize(frame.position - frame.target)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), direction))
        let up = simd_cross(direction, right)
        let verticalTangent = tan(PreviewCameraFrame.verticalFieldOfView * .pi / 360)
        let horizontalTangent = verticalTangent * Float(viewport.width / viewport.height)
        for index in 0..<8 {
            let corner = SIMD3<Float>(
                index & 1 == 0 ? bounds.min.x : bounds.max.x,
                index & 2 == 0 ? bounds.min.y : bounds.max.y,
                index & 4 == 0 ? bounds.min.z : bounds.max.z
            ) - frame.position
            let depth = -simd_dot(corner, direction)
            #expect(depth > frame.near)
            #expect(depth < frame.far)
            #expect(abs(simd_dot(corner, right)) / depth < horizontalTangent)
            #expect(abs(simd_dot(corner, up)) / depth < verticalTangent)
        }
        #expect(frame.target == center)
    }

    @Test("Empty bounds and a zero viewport do not poison initial layout")
    func invalidInputs() {
        #expect(PreviewCameraFrame.fitting(.empty, viewport: CGSize(width: 400, height: 800)) == nil)
        #expect(PreviewCameraFrame.fitting(BoundingBox(min: .zero, max: .one), viewport: .zero) == nil)
    }

    @MainActor
    @Test("Preview refits on resize and new documents while patches preserve camera pose")
    func sceneLifecycleAndResize() throws {
        let view = try #require(ARViewFactory.make(.nonARSim) as? PreviewARView)
        let renderer = SceneRenderer()
        try renderer.attach(to: view)
        view.frame = CGRect(x: 0, y: 0, width: 393, height: 852)

        let recipe = GeometryRecipe.box(size: Vec3(0.6, 2.21, 1.067))
        let definition = GeometryDefinition(geometryId: "asset", contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
        var document = SceneDocument(documentId: "first", geometryDefinitions: [definition], nodes: [
            SceneNode(nodeId: "root", geometryId: "asset", semantic: .init(name: "Assembly"),
                      provenance: .init(origin: .generated, factualSupport: .illustrative, sourceRefs: []))
        ])
        try renderer.loadScene(document)
        let portraitPosition = view.previewCamera.position
        let originalScale = try #require(renderer.entity(for: "root")).scale
        document.nodes[0].transform.translation = Vec3(10, 0, 0)
        try renderer.loadScene(document)
        #expect(view.previewCamera.position == portraitPosition)
        #expect(renderer.entity(for: "root")?.scale == originalScale)

        view.frame = CGRect(x: 0, y: 0, width: 852, height: 393)
        #if os(macOS)
        view.layout()
        #else
        view.layoutSubviews()
        #endif
        let landscapePosition = view.previewCamera.position
        #expect(landscapePosition != portraitPosition)
        // Resizing still frames the captured assembly, not its moved patch pose.
        #expect(landscapePosition.x < 10)

        document.documentId = "second"
        try renderer.loadScene(document)
        #expect(view.previewCamera.position.x > 10)
        #expect(renderer.entity(for: "root")?.scale == originalScale)
    }
}
