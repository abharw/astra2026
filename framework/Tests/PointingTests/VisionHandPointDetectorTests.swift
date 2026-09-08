#if canImport(Vision)
@testable import SpatialApple
import Testing

@Test("a completed Vision result remains deliverable while newer frames wait")
func delayedVisionResultDoesNotStarveBehindNewerFrames() {
    var gate = PointingFrameDeliveryGate()

    let acceptsFirst = gate.acceptsSubmission(10.000)
    let acceptsSecond = gate.acceptsSubmission(10.016)
    let acceptsThird = gate.acceptsSubmission(10.032)
    #expect(acceptsFirst)
    #expect(acceptsSecond)
    #expect(acceptsThird)

    // Vision began on the first frame. The later frames occupy only the bounded
    // latest slot; they must not erase this still-fresh completed result.
    let deliversSlowFirst = gate.acceptsCompletedResult(10.000)
    let deliversLatest = gate.acceptsCompletedResult(10.032)
    let rejectsLateMiddle = gate.acceptsCompletedResult(10.016)
    #expect(deliversSlowFirst)
    #expect(deliversLatest)
    #expect(!rejectsLateMiddle)
}

@Test("automatic search does not run inference at the camera frame rate")
func automaticSearchBoundsCameraFrames() {
    var policy = PointingFrameSamplingPolicy()
    let accepted = (0..<120).filter { index in
        policy.acceptsFrame(at: Double(index) / 60)
    }

    // Two seconds of 60 Hz camera input admit ten requests at 5 Hz.
    #expect(accepted.count == 10)
    #expect(accepted.first == 0)
    #expect(accepted.last == 108)
}

@Test("a recognized hand raises sampling to 15 Hz then absence lowers it")
func automaticTrackingAdaptsToHandPresence() {
    var policy = PointingFrameSamplingPolicy()
    var trackedFrames = 0
    for index in 0..<60 {
        let timestamp = Double(index) / 60
        if policy.acceptsFrame(at: timestamp) {
            trackedFrames += 1
            policy.observedHand(at: timestamp)
        }
    }
    #expect(trackedFrames == 15)

    // No more positive results: after the brief tracking hold, search resumes
    // without a manual state toggle or a continuously running 60 Hz model.
    let absentFrames = (120..<240).filter { index in
        policy.acceptsFrame(at: Double(index) / 60)
    }
    #expect(absentFrames.count == 10)
}

@Test("invalid and old frame timestamps cannot bypass inference limits")
func automaticSamplingRejectsInvalidFrames() {
    var policy = PointingFrameSamplingPolicy()
    let first = policy.acceptsFrame(at: 10)
    let duplicate = policy.acceptsFrame(at: 10)
    let old = policy.acceptsFrame(at: 9)
    let nan = policy.acceptsFrame(at: .nan)
    let infinite = policy.acceptsFrame(at: .infinity)
    let negative = policy.acceptsFrame(at: -1)
    let next = policy.acceptsFrame(at: 10.2)
    #expect(first)
    #expect(!duplicate)
    #expect(!old)
    #expect(!nan)
    #expect(!infinite)
    #expect(!negative)
    #expect(next)
}
#endif
