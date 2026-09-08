import Foundation
import SpatialApple

struct ReplayCase: Identifiable, Hashable, Sendable {
    enum Step: Hashable, Sendable {
        case point(x: Double, y: Double, confidence: Double, time: TimeInterval)
        case handLost(time: TimeInterval)
        case expire(time: TimeInterval)
        case beginSpeech(time: TimeInterval)
    }

    let id: String
    let title: String
    let purpose: String
    let steps: [Step]
    let expectedSpeechTarget: String?
    let expectsRejectedObservation: Bool

    static let stableTargetLock = ReplayCase(
        id: "stable-target-lock",
        title: "Stable target → speech lock",
        purpose: "A fresh, stable hover locks the same semantic node when speech starts.",
        steps: [
            .point(x: 0.22, y: 0.55, confidence: 0.94, time: 1.00),
            .point(x: 0.225, y: 0.552, confidence: 0.93, time: 1.08),
            .point(x: 0.23, y: 0.55, confidence: 0.95, time: 1.16),
            .beginSpeech(time: 1.18),
        ],
        expectedSpeechTarget: "rack.compute-left",
        expectsRejectedObservation: false
    )

    static let lowConfidenceLoss = ReplayCase(
        id: "low-confidence-loss",
        title: "Low confidence clears hover",
        purpose: "An uncertain point does not silently lock an earlier hover.",
        steps: [
            .point(x: 0.22, y: 0.55, confidence: 0.94, time: 2.00),
            .point(x: 0.22, y: 0.55, confidence: 0.30, time: 2.08),
            .beginSpeech(time: 2.10),
        ],
        expectedSpeechTarget: nil,
        expectsRejectedObservation: false
    )

    static let staleObservation = ReplayCase(
        id: "stale-observation",
        title: "Stale result rejected",
        purpose: "A late Vision result cannot replace newer cursor state.",
        steps: [
            .point(x: 0.22, y: 0.55, confidence: 0.94, time: 3.00),
            .point(x: 0.80, y: 0.55, confidence: 0.94, time: 2.90),
            .expire(time: 3.40),
        ],
        expectedSpeechTarget: nil,
        expectsRejectedObservation: true
    )

    static let edgeSweep = ReplayCase(
        id: "edge-sweep",
        title: "Image edge mapping",
        purpose: "Exposes horizontal mirror, vertical flip, and viewport-edge errors.",
        steps: [
            .point(x: 0.01, y: 0.01, confidence: 0.99, time: 4.00),
            .point(x: 0.99, y: 0.01, confidence: 0.99, time: 4.06),
            .point(x: 0.99, y: 0.99, confidence: 0.99, time: 4.12),
            .point(x: 0.01, y: 0.99, confidence: 0.99, time: 4.18),
        ],
        expectedSpeechTarget: nil,
        expectsRejectedObservation: false
    )

    static let targetBoundaryJitter = ReplayCase(
        id: "target-boundary-jitter",
        title: "Adjacent target jitter",
        purpose: "Alternating neighbors do not become a stable target.",
        steps: [
            .point(x: 0.20, y: 0.52, confidence: 0.96, time: 5.00),
            .point(x: 0.80, y: 0.52, confidence: 0.96, time: 5.07),
            .point(x: 0.20, y: 0.52, confidence: 0.96, time: 5.14),
            .point(x: 0.80, y: 0.52, confidence: 0.96, time: 5.21),
            .beginSpeech(time: 5.23),
        ],
        expectedSpeechTarget: nil,
        expectsRejectedObservation: false
    )

    static let lossAndReacquire = ReplayCase(
        id: "loss-and-reacquire",
        title: "Hand loss → fresh reacquisition",
        purpose: "Hand loss clears transient hover and a later sequence earns a fresh lock.",
        steps: [
            .point(x: 0.22, y: 0.55, confidence: 0.95, time: 6.00),
            .point(x: 0.22, y: 0.55, confidence: 0.95, time: 6.14),
            .handLost(time: 6.20),
            .point(x: 0.78, y: 0.55, confidence: 0.95, time: 6.30),
            .point(x: 0.78, y: 0.55, confidence: 0.95, time: 6.44),
            .beginSpeech(time: 6.46),
        ],
        expectedSpeechTarget: "rack.cooling-right",
        expectsRejectedObservation: false
    )

    static let all: [ReplayCase] = [
        .stableTargetLock,
        .lowConfidenceLoss,
        .staleObservation,
        .edgeSweep,
        .targetBoundaryJitter,
        .lossAndReacquire,
    ]
}

struct ReplayRunResult: Sendable {
    let update: PointingResolverUpdate
    let speechLock: PointingSpeechLock?
    let events: [EvidenceEvent]
}

enum ReplayRunner {
    static let viewportWidth = 800.0
    static let viewportHeight = 560.0
    static let sceneID = "scene-pointing-replay"

    /// An identity display transform fixture. The shared mapper still performs
    /// Vision's required lower-left to upper-left y-axis conversion.
    static let fixtureDisplayTransform = PointingViewportTransform(
        a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0
    )

    static func target(for point: PointingScreenPoint) -> PointingTarget? {
        guard point.x >= 0, point.y >= 0,
              point.x <= viewportWidth, point.y <= viewportHeight else {
            return nil
        }
        if point.y < 90 || point.y > 500 { return nil }
        return PointingTarget(nodeID: point.x < viewportWidth / 2 ? "rack.compute-left" : "rack.cooling-right")
    }

    static func run(_ replay: ReplayCase) -> ReplayRunResult {
        var resolver = PointingResolver()
        var update = resolver.expire(at: 0)
        var lock: PointingSpeechLock?
        var events: [EvidenceEvent] = [
            EvidenceEvent(
                kind: .runStarted,
                timestamp: replay.steps.first?.timestamp ?? 0,
                source: .syntheticLandmarks,
                caseID: replay.id,
                detail: replay.purpose
            ),
        ]

        for step in replay.steps {
            switch step {
            case let .point(x, y, confidence, time):
                let mapped = fixtureDisplayTransform.mapVisionPoint(
                    PointingNormalizedPoint(x: x, y: y),
                    viewportWidth: viewportWidth,
                    viewportHeight: viewportHeight
                )
                update = resolver.ingest(
                    PointingScreenObservation(point: mapped, confidence: confidence, timestamp: time),
                    now: time,
                    hitTest: target(for:)
                )
                events.append(
                    EvidenceEvent(
                        kind: update.rejectedObservation ? .failure : .observation,
                        timestamp: time,
                        source: .syntheticLandmarks,
                        caseID: replay.id,
                        detail: "Synthetic Vision-space point (\(x), \(y)) mapped to screen (\(mapped.x), \(mapped.y)); confidence \(confidence)",
                        targetNodeID: update.hover?.target.nodeID,
                        observationAgeMilliseconds: 0
                    )
                )
            case let .handLost(time):
                update = resolver.handLost(at: time)
                events.append(
                    EvidenceEvent(
                        kind: .targetChanged,
                        timestamp: time,
                        source: .syntheticLandmarks,
                        caseID: replay.id,
                        detail: "Synthetic hand-loss marker cleared transient tracking"
                    )
                )
            case let .expire(time):
                update = resolver.expire(at: time)
                events.append(
                    EvidenceEvent(
                        kind: .targetChanged,
                        timestamp: time,
                        source: .syntheticLandmarks,
                        caseID: replay.id,
                        detail: "Resolver expiration evaluated"
                    )
                )
            case let .beginSpeech(time):
                lock = resolver.beginSpeech(sceneID: sceneID, at: time)
                update = resolver.expire(at: time)
                events.append(
                    EvidenceEvent(
                        kind: .speechLocked,
                        timestamp: time,
                        source: .syntheticLandmarks,
                        caseID: replay.id,
                        detail: lock == nil ? "Speech began without a valid target lock" : "Speech locked a fresh stable target",
                        targetNodeID: lock?.selection.nodeID,
                        observationAgeMilliseconds: lock.map { (time - $0.selection.observationTimestamp) * 1_000 }
                    )
                )
            }
        }

        events.append(
            EvidenceEvent(
                kind: .runFinished,
                timestamp: replay.steps.last?.timestamp ?? 0,
                source: .syntheticLandmarks,
                caseID: replay.id,
                detail: "Replay finished; synthetic input does not establish Vision accuracy",
                targetNodeID: lock?.selection.nodeID
            )
        )
        return ReplayRunResult(update: update, speechLock: lock, events: events)
    }
}

private extension ReplayCase.Step {
    var timestamp: TimeInterval {
        switch self {
        case .point(_, _, _, let time), .handLost(let time), .expire(let time), .beginSpeech(let time):
            time
        }
    }
}
