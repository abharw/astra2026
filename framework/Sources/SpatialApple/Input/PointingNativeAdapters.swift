#if canImport(CoreGraphics)
import CoreGraphics

public extension PointingViewportTransform {
    init(displayTransform: CGAffineTransform) {
        self.init(
            a: Double(displayTransform.a),
            b: Double(displayTransform.b),
            c: Double(displayTransform.c),
            d: Double(displayTransform.d),
            tx: Double(displayTransform.tx),
            ty: Double(displayTransform.ty)
        )
    }
}
#endif

#if canImport(ARKit) && canImport(UIKit) && canImport(ImageIO)
import ARKit
import ImageIO
import UIKit

/// Bridges frames from the app-owned AR session into Vision and maps landmarks
/// through that frame's display transform. The owning runtime remains the
/// `ARSessionDelegate`; it calls `submit` from its existing frame callback.
@MainActor
public final class ARPointingFrameAdapter {
    /// Timestamp-preserving result stream for the runtime. Feed `.observation`
    /// into `PointingResolver.ingest` and `.noHand` into `handLost(at:)`.
    public var onResult: ((PointingScreenDetectionResult) -> Void)?
    /// Convenience display callback. Runtime selection logic should use
    /// `onResult`, because `nil` alone has no frame timestamp.
    public var onObservation: ((PointingScreenObservation?) -> Void)?
    public var onDetectionFailure: ((String) -> Void)?

    private let detector: VisionHandPointDetector
    private var viewportGeneration = 0
    private var viewportDescriptor: ViewportDescriptor?

    public init(detector: VisionHandPointDetector = .init()) {
        self.detector = detector
    }

    /// Call when orientation, viewport size, or the owning AR session changes.
    /// Results started with an older transform are dropped rather than mapped into
    /// a newly laid-out viewport.
    public func invalidateViewport() {
        viewportGeneration &+= 1
        viewportDescriptor = nil
        detector.discardPendingFrame()
    }

    /// Submits a frame supplied by an existing AR session. `ARFrame` display
    /// transforms expect raw `capturedImage` coordinates, so this adapter passes
    /// `.up` to Vision and maps the resulting raw-image landmark once. A separate
    /// camera pipeline that supplies an EXIF-oriented image must use
    /// `VisionHandPointDetector` directly and undo that orientation before it
    /// applies its own viewport transform. This class never configures an AR
    /// session or camera.
    public func submit(
        frame: ARFrame,
        interfaceOrientation: UIInterfaceOrientation,
        viewportSize: CGSize
    ) {
        guard viewportSize.width > 0, viewportSize.height > 0 else {
            invalidateViewport()
            onObservation?(nil)
            return
        }

        let nextViewport = ViewportDescriptor(
            interfaceOrientation: interfaceOrientation,
            size: viewportSize
        )
        if let viewportDescriptor, viewportDescriptor != nextViewport {
            // A completed Vision result contains coordinates for the camera frame
            // but the display transform is specific to this exact viewport.
            // Discard the queued frame and fence the in-flight result before it
            // can be applied using an old landscape/portrait or size mapping.
            viewportGeneration &+= 1
            detector.discardPendingFrame()
        }
        viewportDescriptor = nextViewport

        let transform = PointingViewportTransform(
            displayTransform: frame.displayTransform(
                for: interfaceOrientation,
                viewportSize: viewportSize
            )
        )
        let generation = viewportGeneration
        let viewportWidth = Double(viewportSize.width)
        let viewportHeight = Double(viewportSize.height)

        detector.submit(
            pixelBuffer: frame.capturedImage,
            orientation: .up,
            timestamp: frame.timestamp
        ) { [weak self] result in
            Task { @MainActor [weak self] in
                self?.accept(
                    result,
                    transform: transform,
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight,
                    generation: generation
                )
            }
        }
    }

    private func accept(
        _ result: VisionHandPointDetector.Result,
        transform: PointingViewportTransform,
        viewportWidth: Double,
        viewportHeight: Double,
        generation: Int
    ) {
        guard generation == viewportGeneration else {
            return
        }

        switch result {
        case .observation(let imageObservation):
            let point = transform.mapVisionPoint(
                imageObservation.visionNormalizedPoint,
                viewportWidth: viewportWidth,
                viewportHeight: viewportHeight
            )
            let observation = PointingScreenObservation(
                point: point,
                confidence: imageObservation.confidence,
                timestamp: imageObservation.timestamp
            )
            onResult?(.observation(observation))
            onObservation?(observation)
        case .noHand(let timestamp):
            onResult?(.noHand(timestamp: timestamp))
            onObservation?(nil)
        case .failed(let timestamp, let reason):
            onResult?(.failed(timestamp: timestamp, reason: reason))
            onDetectionFailure?(reason)
            onObservation?(nil)
        }
    }

    private struct ViewportDescriptor: Equatable {
        let interfaceOrientation: UIInterfaceOrientation
        let size: CGSize
    }
}
#endif
