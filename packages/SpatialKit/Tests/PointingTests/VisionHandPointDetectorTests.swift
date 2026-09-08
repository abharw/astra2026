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
#endif
