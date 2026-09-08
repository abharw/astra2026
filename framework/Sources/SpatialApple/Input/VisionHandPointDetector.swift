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
        /// Search cheaply when no hand is visible, then increase responsiveness
        /// while a recently recognized fingertip remains in the camera frame.
        public var searchFramesPerSecond: Double
        public var trackingFramesPerSecond: Double

        public init(
            minimumConfidence: Double = 0.55,
            searchFramesPerSecond: Double = 5,
            trackingFramesPerSecond: Double = 15
        ) {
            self.minimumConfidence = minimumConfidence
            self.searchFramesPerSecond = searchFramesPerSecond
            self.trackingFramesPerSecond = trackingFramesPerSecond
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
    private var samplingPolicy: PointingFrameSamplingPolicy
    /// The serial processing queue is the sole owner after initialization.
    private let handPoseRequest: VNDetectHumanHandPoseRequest

    public init(
        configuration: Configuration = .init(),
        resultQueue: DispatchQueue = .main
    ) {
        self.configuration = configuration
        self.resultQueue = resultQueue
        self.samplingPolicy = PointingFrameSamplingPolicy(
            searchFramesPerSecond: configuration.searchFramesPerSecond,
            trackingFramesPerSecond: configuration.trackingFramesPerSecond
        )
        self.handPoseRequest = VNDetectHumanHandPoseRequest()
        self.handPoseRequest.maximumHandCount = 1
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
        guard samplingPolicy.acceptsFrame(at: timestamp),
              deliveryGate.acceptsSubmission(timestamp) else {
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
            request: handPoseRequest,
            pixelBuffer: frame.pixelBuffer,
            orientation: frame.orientation,
            timestamp: frame.timestamp,
            minimumConfidence: configuration.minimumConfidence
        )

        let nextFrame: QueuedFrame?
        stateLock.lock()
        if case .observation(let observation) = result {
            samplingPolicy.observedHand(at: observation.timestamp)
        }
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
        request: VNDetectHumanHandPoseRequest,
        pixelBuffer: CVPixelBuffer,
        orientation: CGImagePropertyOrientation,
        timestamp: TimeInterval,
        minimumConfidence: Double
    ) -> Result {
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

/// Bounds inference independently of the camera's display rate. A brief hold
/// avoids switching rates on a single occluded frame. It does not keep a cursor
/// visible: no-hand results still immediately clear transient pointing feedback.
struct PointingFrameSamplingPolicy: Sendable {
    private let searchInterval: TimeInterval
    private let trackingInterval: TimeInterval
    private let trackingHoldDuration: TimeInterval = 0.5
    private var lastAcceptedTimestamp: TimeInterval?
    private var lastHandTimestamp: TimeInterval?

    init(searchFramesPerSecond: Double = 5, trackingFramesPerSecond: Double = 15) {
        let searchRate = searchFramesPerSecond.isFinite ? min(max(searchFramesPerSecond, 1), 15) : 5
        let trackingRate = trackingFramesPerSecond.isFinite ? min(max(trackingFramesPerSecond, searchRate), 30) : 15
        self.searchInterval = 1 / searchRate
        self.trackingInterval = 1 / trackingRate
    }

    mutating func acceptsFrame(at timestamp: TimeInterval) -> Bool {
        guard timestamp.isFinite, timestamp >= 0 else { return false }
        let recentlySawHand = lastHandTimestamp.map {
            timestamp >= $0 && timestamp - $0 <= trackingHoldDuration
        } ?? false
        let interval = recentlySawHand ? trackingInterval : searchInterval
        if let lastAcceptedTimestamp {
            guard timestamp > lastAcceptedTimestamp,
                  timestamp - lastAcceptedTimestamp + 0.000_001 >= interval else { return false }
        }
        lastAcceptedTimestamp = timestamp
        return true
    }

    mutating func observedHand(at timestamp: TimeInterval) {
        guard timestamp.isFinite, timestamp >= 0,
              lastHandTimestamp.map({ timestamp > $0 }) ?? true else { return }
        lastHandTimestamp = timestamp
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
