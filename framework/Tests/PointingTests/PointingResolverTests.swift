import Foundation
import SpatialApple
import Testing

@Suite("Screen-aligned pointing")
struct PointingResolverTests {
    @Test("Vision lower-left coordinates map through the viewport transform")
    func mapsVisionCoordinates() {
        let transform = PointingViewportTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        let point = transform.mapVisionPoint(
            PointingNormalizedPoint(x: 0.25, y: 0.75),
            viewportWidth: 1_000,
            viewportHeight: 800
        )

        #expect(point == PointingScreenPoint(x: 250, y: 200))
    }

    @Test("portrait, landscape, and mirrored display transforms map raw-camera landmarks once")
    func mapsDisplayOrientationFixtures() {
        // The point is Vision lower-left; the transforms model the normalized
        // raw-camera -> viewport matrices supplied by a native renderer.
        let landmark = PointingNormalizedPoint(x: 0.2, y: 0.7)
        let landscape = PointingViewportTransform(a: 1, b: 0, c: 0, d: 1, tx: 0, ty: 0)
        let portrait = PointingViewportTransform(a: 0, b: 1, c: -1, d: 0, tx: 1, ty: 0)
        let mirrored = PointingViewportTransform(a: -1, b: 0, c: 0, d: 1, tx: 1, ty: 0)

        let landscapePoint = landscape.mapVisionPoint(landmark, viewportWidth: 100, viewportHeight: 100)
        let portraitPoint = portrait.mapVisionPoint(landmark, viewportWidth: 100, viewportHeight: 100)
        let mirroredPoint = mirrored.mapVisionPoint(landmark, viewportWidth: 100, viewportHeight: 100)

        #expect(approximatelyEqual(landscapePoint, PointingScreenPoint(x: 20, y: 30)))
        #expect(approximatelyEqual(portraitPoint, PointingScreenPoint(x: 70, y: 20)))
        #expect(approximatelyEqual(mirroredPoint, PointingScreenPoint(x: 80, y: 30)))
    }

    @Test("a stable hover locks at speech start and later hover cannot retarget it")
    func locksStableTargetAtSpeechStart() throws {
        var resolver = PointingResolver(
            configuration: .init(
                minimumConfidence: 0.5,
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0.1,
                stableMovementRadius: 30,
                maximumObservationAge: 0.5
            )
        )
        let sceneID = "scene-lock"

        _ = resolver.ingest(observation(10, x: 100, y: 100), now: 10) { _ in
            PointingTarget(nodeID: "first")
        }
        let stable = resolver.ingest(observation(10.11, x: 102, y: 99), now: 10.11) { _ in
            PointingTarget(nodeID: "first")
        }
        #expect(stable.stableHover?.target.nodeID == "first")

        let requestedLock = resolver.beginSpeech(sceneID: sceneID, at: 10.12)
        let lock = try #require(requestedLock)
        _ = resolver.ingest(observation(10.2, x: 400, y: 300), now: 10.2) { _ in
            PointingTarget(nodeID: "second")
        }

        let state = resolver.expire(at: 10.2)
        #expect(lock.selection.nodeID == "first")
        #expect(state.activeSpeechLock == lock)
        #expect(state.confirmedSelection?.nodeID == "first")
    }

    @Test("stale and out-of-order landmarks cannot replace a stable target")
    func rejectsStaleAndOutOfOrderObservations() {
        var resolver = PointingResolver(
            configuration: .init(
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0,
                maximumObservationAge: 0.25
            )
        )

        let accepted = resolver.ingest(observation(4, x: 50, y: 60), now: 4) { _ in
            PointingTarget(nodeID: "current")
        }
        #expect(accepted.hover?.target.nodeID == "current")

        let outOfOrder = resolver.ingest(observation(3.9, x: 300, y: 300), now: 4) { _ in
            PointingTarget(nodeID: "old")
        }
        let stale = resolver.ingest(observation(4.01, x: 300, y: 300), now: 4.4) { _ in
            PointingTarget(nodeID: "stale")
        }

        #expect(outOfOrder.rejectedObservation)
        #expect(stale.rejectedObservation)
        #expect(stale.hover?.target.nodeID == "current")
    }

    @Test("expiry clears a cursor left behind by a rejected stale observation")
    func expiresAfterStaleRejection() {
        var resolver = PointingResolver(
            configuration: .init(
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0,
                maximumObservationAge: 0.25
            )
        )

        _ = resolver.ingest(observation(1, x: 30, y: 40), now: 1) { _ in
            PointingTarget(nodeID: "current")
        }
        let stale = resolver.ingest(observation(1.01, x: 400, y: 400), now: 2) { _ in
            PointingTarget(nodeID: "late")
        }
        #expect(stale.rejectedObservation)
        #expect(stale.cursor != nil)

        let expired = resolver.expire(at: 2)
        #expect(expired.cursor == nil)
        #expect(expired.hover == nil)
        #expect(expired.stableHover == nil)
    }

    @Test("expiry preserves an already-bound speech lock")
    func expiryPreservesActiveSpeechLock() throws {
        var resolver = PointingResolver(
            configuration: .init(
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0,
                maximumObservationAge: 0.1
            )
        )
        let sceneID = "scene-speech-expiry"

        _ = resolver.ingest(observation(3, x: 10, y: 10), now: 3) { _ in
            PointingTarget(nodeID: "bound")
        }
        _ = resolver.ingest(observation(3.001, x: 10, y: 10), now: 3.001) { _ in
            PointingTarget(nodeID: "bound")
        }
        let requestedLock = resolver.beginSpeech(sceneID: sceneID, at: 3.01)
        let lock = try #require(requestedLock)

        let expired = resolver.expire(at: 3.2)
        #expect(expired.cursor == nil)
        #expect(expired.hover == nil)
        #expect(expired.activeSpeechLock == lock)
    }

    @Test("an uncertain active pointing attempt cannot fall back to an old selection")
    func refusesOldSelectionDuringUncertainPointing() throws {
        var resolver = PointingResolver(
            configuration: .init(
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0,
                maximumObservationAge: 0.5
            )
        )
        let sceneID = "scene-uncertain"

        _ = resolver.ingest(observation(8, x: 10, y: 10), now: 8) { _ in
            PointingTarget(nodeID: "saved")
        }
        _ = resolver.ingest(observation(8.001, x: 10, y: 10), now: 8.001) { _ in
            PointingTarget(nodeID: "saved")
        }
        let initialSelection = resolver.confirmStableTarget(sceneID: sceneID, at: 8.01)
        _ = try #require(initialSelection)

        _ = resolver.ingest(observation(8.1, x: 500, y: 500), now: 8.1) { _ in nil }
        let uncertainSpeechLock = resolver.beginSpeech(sceneID: sceneID, at: 8.11)
        #expect(uncertainSpeechLock == nil)

        _ = resolver.handLost(at: 8.2)
        let recoveredSpeechLock = resolver.beginSpeech(sceneID: sceneID, at: 8.21)
        let recovered = try #require(recoveredSpeechLock)
        #expect(recovered.selection.nodeID == "saved")
    }

    @Test("expiry clears transient hover while preserving an explicit selection")
    func expiresTransientTracking() throws {
        var resolver = PointingResolver(
            configuration: .init(
                cursorSmoothingFactor: 1,
                stableDwellDuration: 0,
                maximumObservationAge: 0.1
            )
        )
        let sceneID = "scene-expiry"
        _ = resolver.ingest(observation(2, x: 10, y: 10), now: 2) { _ in
            PointingTarget(nodeID: "kept")
        }
        _ = resolver.ingest(observation(2.001, x: 10, y: 10), now: 2.001) { _ in
            PointingTarget(nodeID: "kept")
        }
        let selection = resolver.confirmStableTarget(sceneID: sceneID, at: 2.01)
        _ = try #require(selection)

        let expired = resolver.expire(at: 2.11)
        #expect(expired.cursor == nil)
        #expect(expired.hover == nil)
        #expect(expired.stableHover == nil)
        #expect(expired.confirmedSelection?.nodeID == "kept")
    }

    @Test("automatic hand disappearance hides feedback without canceling speech or selection")
    func handLossPreservesSpeechAndSelection() throws {
        var resolver = PointingResolver(configuration: .init(
            cursorSmoothingFactor: 1, stableDwellDuration: 0
        ))
        _ = resolver.ingest(observation(12, x: 20, y: 30), now: 12) { _ in
            PointingTarget(nodeID: "server03")
        }
        _ = resolver.ingest(observation(12.1, x: 20, y: 30), now: 12.1) { _ in
            PointingTarget(nodeID: "server03")
        }
        let requestedLock = resolver.beginSpeech(sceneID: "rack", at: 12.11)
        let lock = try #require(requestedLock)

        let lost = resolver.handLost(at: 12.2)
        #expect(lost.cursor == nil)
        #expect(lost.hover == nil)
        #expect(lost.stableHover == nil)
        #expect(lost.confirmedSelection?.nodeID == "server03")
        #expect(lost.activeSpeechLock == lock)

        let suspended = resolver.clearTransientTracking()
        #expect(suspended.activeSpeechLock == lock)
        #expect(suspended.confirmedSelection?.nodeID == "server03")
    }

    @Test("late hand-loss and recognition events cannot undo newer feedback")
    func handLossRejectsOutOfOrderEvents() {
        var resolver = PointingResolver()
        _ = resolver.ingest(observation(20, x: 20, y: 30), now: 20) { _ in
            PointingTarget(nodeID: "server03")
        }
        let lateLoss = resolver.handLost(at: 19.9)
        #expect(lateLoss.rejectedObservation)
        #expect(lateLoss.cursor != nil)

        let loss = resolver.handLost(at: 20.2)
        #expect(loss.cursor == nil)
        let lateObservation = resolver.ingest(observation(20.1, x: 20, y: 30), now: 20.3) { _ in
            PointingTarget(nodeID: "server03")
        }
        #expect(lateObservation.rejectedObservation)
        #expect(lateObservation.cursor == nil)
    }

    private func observation(_ timestamp: TimeInterval, x: Double, y: Double) -> PointingScreenObservation {
        PointingScreenObservation(
            point: PointingScreenPoint(x: x, y: y),
            confidence: 0.9,
            timestamp: timestamp
        )
    }

    private func approximatelyEqual(_ lhs: PointingScreenPoint, _ rhs: PointingScreenPoint) -> Bool {
        abs(lhs.x - rhs.x) < 0.000_001 && abs(lhs.y - rhs.y) < 0.000_001
    }
}
