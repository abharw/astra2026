import CoreGraphics
import RealityKit
import simd

/// Fits a view to physical geometry by moving the preview camera, never by
/// normalizing the scene or changing an assembly's inherited scale.
struct PreviewCameraFrame {
    let target: SIMD3<Float>
    let position: SIMD3<Float>
    let near: Float
    let far: Float

    static let verticalFieldOfView: Float = 50
    static let viewingDirection = simd_normalize(SIMD3<Float>(0.9, 0.48, 1.45))

    static func fitting(_ bounds: BoundingBox, viewport: CGSize) -> Self? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0,
              (0..<3).allSatisfy({ bounds.min[$0].isFinite && bounds.max[$0].isFinite }),
              (0..<3).allSatisfy({ bounds.max[$0] >= bounds.min[$0] }),
              simd_length(bounds.extents) > 0
        else { return nil }

        let verticalTangent = tan(verticalFieldOfView * .pi / 360)
        let horizontalTangent = verticalTangent * Float(viewport.width / viewport.height)
        let right = simd_normalize(simd_cross(SIMD3<Float>(0, 1, 0), viewingDirection))
        let up = simd_cross(viewingDirection, right)
        let margin: Float = 1.16
        var distance: Float = 0
        var depthExtent: Float = 0

        // A diagonal camera sees both the width and depth of a box. Testing all
        // corners avoids the clipping caused by fitting only width and height.
        for index in 0..<8 {
            let corner = SIMD3<Float>(
                index & 1 == 0 ? bounds.min.x : bounds.max.x,
                index & 2 == 0 ? bounds.min.y : bounds.max.y,
                index & 4 == 0 ? bounds.min.z : bounds.max.z
            ) - bounds.center
            let depth = simd_dot(corner, viewingDirection)
            distance = max(distance, depth + margin * abs(simd_dot(corner, right)) / horizontalTangent)
            distance = max(distance, depth + margin * abs(simd_dot(corner, up)) / verticalTangent)
            depthExtent = max(depthExtent, abs(depth))
        }
        distance = max(distance, depthExtent + simd_length(bounds.extents) * 0.05)
        guard distance.isFinite else { return nil }
        return Self(
            target: bounds.center,
            position: bounds.center + viewingDirection * distance,
            near: max(0.000_001, (distance - depthExtent) * 0.5),
            far: (distance + depthExtent) * 1.5
        )
    }
}

/// Only ARViewFactory's non-AR surface uses this camera. A physical AR camera
/// remains owned by ARKit. Layout changes refit the original framing bounds;
/// scene edits, explosions, and selections do not make the camera jump.
@MainActor
final class PreviewARView: ARView {
    let previewCamera = PerspectiveCamera()
    private var framingDocumentID: String?
    private var framingBounds: BoundingBox?
    private var framedViewport = CGSize.zero

    func captureFramingBounds(for documentID: String, bounds: @autoclosure () -> BoundingBox) {
        if framingDocumentID != documentID {
            framingDocumentID = documentID
            framingBounds = nil
        }
        guard framingBounds == nil else { return }
        let candidate = bounds()
        // An empty document can acquire its first geometry in a later patch.
        guard !candidate.isEmpty, simd_length(candidate.extents).isFinite,
              simd_length(candidate.extents) > 0 else { return }
        framingBounds = candidate
        updatePreviewFraming()
    }

    private func updatePreviewFraming() {
        framedViewport = bounds.size
        guard let framingBounds,
              let frame = PreviewCameraFrame.fitting(framingBounds, viewport: bounds.size)
        else { return }
        var lens = previewCamera.camera
        lens.fieldOfViewOrientation = .vertical
        lens.fieldOfViewInDegrees = PreviewCameraFrame.verticalFieldOfView
        lens.near = frame.near
        lens.far = frame.far
        previewCamera.camera = lens
        previewCamera.look(at: frame.target, from: frame.position, relativeTo: nil)
    }

    #if os(macOS)
    override func layout() {
        super.layout()
        if framedViewport != bounds.size { updatePreviewFraming() }
    }
    #else
    override func layoutSubviews() {
        super.layoutSubviews()
        if framedViewport != bounds.size { updatePreviewFraming() }
    }
    #endif
}
