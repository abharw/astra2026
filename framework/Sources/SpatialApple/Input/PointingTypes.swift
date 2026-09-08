import Foundation

/// A normalized coordinate from Vision's image space. Vision's origin is at the
/// lower-left corner of the image; convert it with ``PointingViewportTransform``
/// before using it for a screen hit test.
public struct PointingNormalizedPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }
}

/// A location in the rendered viewport, measured in points.
public struct PointingScreenPoint: Sendable, Hashable {
    public let x: Double
    public let y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: Self) -> Double {
        let horizontal = x - other.x
        let vertical = y - other.y
        return (horizontal * horizontal + vertical * vertical).squareRoot()
    }
}

/// The display transform supplied by the native camera renderer.
///
/// ARKit's display transform maps normalized *raw camera-image* coordinates to
/// normalized viewport coordinates. This value form deliberately keeps the
/// resolver independent of ARKit, UIKit, and AppKit.
public struct PointingViewportTransform: Sendable, Hashable {
    public let a: Double
    public let b: Double
    public let c: Double
    public let d: Double
    public let tx: Double
    public let ty: Double

    public init(a: Double, b: Double, c: Double, d: Double, tx: Double, ty: Double) {
        self.a = a
        self.b = b
        self.c = c
        self.d = d
        self.tx = tx
        self.ty = ty
    }

    /// Maps a raw-camera Vision hand landmark into the point-space viewport used
    /// for native entity picking. Vision is lower-left-origin; ARKit display
    /// transforms use upper-left-origin image coordinates, so y is flipped first.
    /// The `ARPointingFrameAdapter` deliberately runs Vision with `.up` against
    /// `ARFrame.capturedImage`, keeping this coordinate domain unambiguous.
    public func mapVisionPoint(
        _ point: PointingNormalizedPoint,
        viewportWidth: Double,
        viewportHeight: Double
    ) -> PointingScreenPoint {
        let imageX = point.x
        let imageY = 1 - point.y
        let viewportX = a * imageX + c * imageY + tx
        let viewportY = b * imageX + d * imageY + ty
        return PointingScreenPoint(
            x: viewportX * viewportWidth,
            y: viewportY * viewportHeight
        )
    }
}

/// The result of detecting a fingertip before any viewport transform is applied.
public struct PointingImageObservation: Sendable, Hashable {
    public let visionNormalizedPoint: PointingNormalizedPoint
    public let confidence: Double
    /// A local monotonic timestamp, normally `ARFrame.timestamp`.
    public let timestamp: TimeInterval

    public init(
        visionNormalizedPoint: PointingNormalizedPoint,
        confidence: Double,
        timestamp: TimeInterval
    ) {
        self.visionNormalizedPoint = visionNormalizedPoint
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// A fingertip observation after it has been mapped into the displayed viewport.
public struct PointingScreenObservation: Sendable, Hashable {
    public let point: PointingScreenPoint
    public let confidence: Double
    /// Must share a local monotonic time base with resolver and speech events.
    public let timestamp: TimeInterval

    public init(point: PointingScreenPoint, confidence: Double, timestamp: TimeInterval) {
        self.point = point
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// A screen-space hand-detection event. Carrying the no-hand timestamp lets the
/// resolver reject a delayed loss event just as it rejects a delayed landmark.
public enum PointingScreenDetectionResult: Sendable, Hashable {
    case observation(PointingScreenObservation)
    case noHand(timestamp: TimeInterval)
    case failed(timestamp: TimeInterval, reason: String)
}

/// A semantic target produced by the native renderer's screen-space hit test.
public struct PointingTarget: Sendable, Hashable {
    public let nodeID: String

    public init(nodeID: String) {
        self.nodeID = nodeID
    }
}

public struct PointingCursor: Sendable, Hashable {
    public let point: PointingScreenPoint
    public let confidence: Double
    public let timestamp: TimeInterval

    public init(point: PointingScreenPoint, confidence: Double, timestamp: TimeInterval) {
        self.point = point
        self.confidence = confidence
        self.timestamp = timestamp
    }
}

/// Temporary local UI feedback. It is never an authored scene mutation.
public struct PointingHover: Sendable, Hashable {
    public let target: PointingTarget
    public let cursor: PointingCursor
    public let isStable: Bool

    public init(target: PointingTarget, cursor: PointingCursor, isStable: Bool) {
        self.target = target
        self.cursor = cursor
        self.isStable = isStable
    }
}

/// A local selection identity. The runtime must still revalidate `nodeID` when
/// admitting the eventual scene request.
public struct PointingSelection: Sendable, Hashable {
    public let sceneID: String
    public let nodeID: String
    public let selectionEventID: UUID
    public let observationTimestamp: TimeInterval

    public init(
        sceneID: String,
        nodeID: String,
        selectionEventID: UUID,
        observationTimestamp: TimeInterval
    ) {
        self.sceneID = sceneID
        self.nodeID = nodeID
        self.selectionEventID = selectionEventID
        self.observationTimestamp = observationTimestamp
    }
}

/// The immutable target captured at speech start. Later pointer movement cannot
/// change this value.
public struct PointingSpeechLock: Sendable, Hashable {
    public let speechLockID: UUID
    public let selection: PointingSelection
    public let lockedAt: TimeInterval

    public init(speechLockID: UUID, selection: PointingSelection, lockedAt: TimeInterval) {
        self.speechLockID = speechLockID
        self.selection = selection
        self.lockedAt = lockedAt
    }
}

public struct PointingResolverUpdate: Sendable, Hashable {
    public let cursor: PointingCursor?
    public let hover: PointingHover?
    public let stableHover: PointingHover?
    public let confirmedSelection: PointingSelection?
    public let activeSpeechLock: PointingSpeechLock?
    /// True when a stale or out-of-order result was ignored.
    public let rejectedObservation: Bool

    public init(
        cursor: PointingCursor?,
        hover: PointingHover?,
        stableHover: PointingHover?,
        confirmedSelection: PointingSelection?,
        activeSpeechLock: PointingSpeechLock?,
        rejectedObservation: Bool
    ) {
        self.cursor = cursor
        self.hover = hover
        self.stableHover = stableHover
        self.confirmedSelection = confirmedSelection
        self.activeSpeechLock = activeSpeechLock
        self.rejectedObservation = rejectedObservation
    }
}
