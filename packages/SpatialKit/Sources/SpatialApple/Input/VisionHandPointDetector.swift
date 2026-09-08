#if canImport(Vision) && canImport(CoreVideo) && canImport(ImageIO)
@preconcurrency import CoreVideo
import Foundation
import ImageIO
import Vision

/// A bounded Vision hand-pose adapter. It accepts camera-owned pixel buffers but
/// never starts camera capture itself. While one Vision request is in flight it
/// retains only the latest newer frame, and it emits completed results in
/// monotonic timestamp order.
public final class VisionHandPointDetector: @unchecked Sendable {
    public struct Configuration: Sendable, Hashable {
        public var minimumConfidence: Double

        public init(minimumConfidence: Double = 0.55) {
            self.minimumConfidence = minimumConfidence
        }
    }

    public enum Result: Sendable, Equatable {
        case observation(PointingImageObservation)
        case noHand(timestamp: TimeInterval)
        case failed(timestamp: TimeInterval, reason: String)
    }

    private let configuration: Configuration
    private let processingQueue = DispatchQueue(label: "com.astra.spatial.pointing.vision")
    private let resultQueue: DispatchQueue
    private let stateLock = NSLock()

    private var isProcessing = false
    private var pendingFrame: QueuedFrame?
    private var deliveryGate = PointingFrameDeliveryGate()

    public init(
        configuration: Configuration = .init(),
        resultQueue: DispatchQueue = .main
    ) {
        self.configuration = configuration
        self.resultQueue = resultQueue
    }

    /// Adds a frame from an existing AR session or webcam capture. `timestamp`
    /// must advance monotonically within one camera stream. Older and duplicate
    /// frames are discarded before Vision work begins.
    public func submit(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval,
        onResult: @escaping @Sendable (Result) -> Void
    ) {
        guard timestamp.isFinite, timestamp >= 0 else {
            return
        }

        let frame = QueuedFrame(
            pixelBuffer: pixelBuffer,
            orientation: orientation,
            timestamp: timestamp,
            onResult: onResult
        )

        let frameToStart: QueuedFrame?
        stateLock.lock()
        guard deliveryGate.acceptsSubmission(timestamp) else {
            stateLock.unlock()
            return
        }
        if isProcessing {
            pendingFrame = frame
            frameToStart = nil
        } else {
            isProcessing = true
            frameToStart = frame
        }
        stateLock.unlock()

        if let frameToStart {
            processingQueue.async { [weak self] in
                self?.process(frameToStart)
            }
        }
    }

    /// Drops the pending latest frame. An already-running Vision request is
    /// allowed to finish and deliver if its timestamp remains in order.
    public func discardPendingFrame() {
        stateLock.lock()
        pendingFrame = nil
        stateLock.unlock()
    }

    private func process(_ frame: QueuedFrame) {
        let result = Self.detect(
            pixelBuffer: frame.pixelBuffer,
            orientation: frame.orientation,
            timestamp: frame.timestamp,
            minimumConfidence: configuration.minimumConfidence
        )

        let nextFrame: QueuedFrame?
        stateLock.lock()
        nextFrame = pendingFrame
        pendingFrame = nil
        if nextFrame == nil {
            isProcessing = false
        }
        stateLock.unlock()

        resultQueue.async { [weak self] in
            guard self?.acceptsCompletedResult(timestamp: frame.timestamp) == true else {
                return
            }
            frame.onResult(result)
        }

        if let nextFrame {
            processingQueue.async { [weak self] in
                self?.process(nextFrame)
            }
        }
    }

    private func acceptsCompletedResult(timestamp: TimeInterval) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return deliveryGate.acceptsCompletedResult(timestamp)
    }

    private static func detect(
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval,
        minimumConfidence: Double
    ) -> Result {
        let request = VNDetectHumanHandPoseRequest()
        request.maximumHandCount = 1

        do {
            let requestHandler = VNImageRequestHandler(
                cvPixelBuffer: pixelBuffer,
                orientation: orientation,
                options: [:]
            )
            try requestHandler.perform([request])

            guard let hand = request.results?.first,
                  let indexTip = try? hand.recognizedPoint(.indexTip),
                  indexTip.confidence >= Float(min(max(minimumConfidence, 0), 1)) else {
                return .noHand(timestamp: timestamp)
            }

            return .observation(
                PointingImageObservation(
                    visionNormalizedPoint: PointingNormalizedPoint(
                        x: Double(indexTip.location.x),
                        y: Double(indexTip.location.y)
                    ),
                    confidence: Double(indexTip.confidence),
                    timestamp: timestamp
                )
            )
        } catch {
            return .failed(timestamp: timestamp, reason: String(describing: error))
        }
    }
}

/// Separates the bounded latest-frame scheduler from result freshness. A frame
/// that was current when Vision began can still be a fresh result when a newer
/// frame is waiting. Suppressing it merely because a newer frame was submitted
/// starves recognition whenever inference takes longer than one camera interval.
/// The resolver applies the actual observation-age bound at delivery time.
struct PointingFrameDeliveryGate: Sendable {
    private var latestSubmittedTimestamp: TimeInterval?
    private var latestDeliveredTimestamp: TimeInterval?

    mutating func acceptsSubmission(_ timestamp: TimeInterval) -> Bool {
        guard latestSubmittedTimestamp.map({ timestamp > $0 }) ?? true else {
            return false
        }
        latestSubmittedTimestamp = timestamp
        return true
    }

    mutating func acceptsCompletedResult(_ timestamp: TimeInterval) -> Bool {
        guard latestDeliveredTimestamp.map({ timestamp > $0 }) ?? true else {
            return false
        }
        latestDeliveredTimestamp = timestamp
        return true
    }
}

private struct QueuedFrame: @unchecked Sendable {
    let pixelBuffer: CVPixelBuffer
    let orientation: CGImagePropertyOrientation
    let timestamp: TimeInterval
    let onResult: @Sendable (VisionHandPointDetector.Result) -> Void
}
#endif
