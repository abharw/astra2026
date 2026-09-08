import Foundation
import Testing

@MainActor
@Suite struct MicrophoneCaptureGateTests {
    @Test
    func acceptedChunksKeepTheirOrderAndCaptureIdentity() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 3)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)
        let payloads = [Data([1, 0]), Data([2, 0]), Data([3, 0])]

        for payload in payloads {
            gate.yield(payload, captureID: captureID)
        }
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == captureID)
        #expect(gate.snapshot() == captureID)
        #expect(result.chunks.map(\.data) == payloads)
        #expect(result.chunks.map(\.captureID) == [captureID, captureID, captureID])
        #expect(result.error == nil)
    }

    @Test(arguments: [2, 32 * 1_024 + 2])
    func rotationRejectsOldCallbacksAndPreservesBufferedIdentity(staleByteCount: Int) async throws {
        let oldID = UUID()
        let (stream, continuation) = makeStream(capacity: 3)
        let gate = MicrophoneCaptureGate(captureID: oldID, continuation: continuation)
        let buffered = Data([1, 0])
        let fresh = Data([3, 0])
        gate.yield(buffered, captureID: oldID)

        let newID = try #require(gate.rotate())
        gate.yield(Data(repeating: 2, count: staleByteCount), captureID: oldID)
        gate.yield(fresh, captureID: newID)
        continuation.finish()
        let result = await drain(stream)

        #expect(newID != oldID)
        #expect(gate.currentCaptureID == newID)
        #expect(gate.snapshot() == newID)
        #expect(result.chunks.map(\.data) == [buffered, fresh])
        #expect(result.chunks.map(\.captureID) == [oldID, newID])
        #expect(result.chunks.filter { $0.captureID == gate.currentCaptureID }.map(\.data) == [fresh])
        #expect(result.error == nil)
    }

    @Test
    func staleFailureCannotTerminateTheRotatedCapture() async throws {
        let oldID = UUID()
        let (stream, continuation) = makeStream(capacity: 1)
        let gate = MicrophoneCaptureGate(captureID: oldID, continuation: continuation)
        let newID = try #require(gate.rotate())
        let fresh = Data([7, 0])

        gate.finish(throwing: CaptureFailure.failed, captureID: oldID)
        gate.yield(fresh, captureID: newID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == newID)
        #expect(result.chunks.map(\.data) == [fresh])
        #expect(result.chunks.map(\.captureID) == [newID])
        #expect(result.error == nil)
    }

    @Test
    func invalidationLetsReplacementCaptureUseTheSameStream() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 2)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)
        let buffered = Data([1, 0])
        gate.yield(buffered, captureID: captureID)

        gate.invalidate()
        let replacementID = UUID()
        let replacementGate = MicrophoneCaptureGate(captureID: replacementID, continuation: continuation)
        let fresh = Data([3, 0])
        replacementGate.yield(fresh, captureID: replacementID)
        gate.yield(Data([2, 0]), captureID: captureID)
        gate.finish(throwing: CaptureFailure.failed, captureID: captureID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == nil)
        #expect(gate.snapshot() == nil)
        #expect(gate.rotate() == nil)
        #expect(replacementGate.currentCaptureID == replacementID)
        #expect(result.chunks.map(\.data) == [buffered, fresh])
        #expect(result.chunks.map(\.captureID) == [captureID, replacementID])
        #expect(result.error == nil)
    }

    @Test
    func currentCaptureFailureIsTerminal() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 1)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)

        gate.finish(throwing: CaptureFailure.failed, captureID: captureID)
        gate.yield(Data([1, 0]), captureID: captureID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == nil)
        #expect(gate.rotate() == nil)
        #expect(result.chunks.isEmpty)
        #expect(result.error as? CaptureFailure == .failed)
    }

    @Test
    func maximumSizedChunkIsAccepted() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 1)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)
        let payload = Data(repeating: 42, count: 32 * 1_024)

        gate.yield(payload, captureID: captureID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == captureID)
        #expect(result.chunks.map(\.data) == [payload])
        #expect(result.error == nil)
    }

    @Test
    func oversizedChunkTerminatesCaptureBeforeItIsBuffered() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 2)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)

        gate.yield(Data(repeating: 42, count: 32 * 1_024 + 2), captureID: captureID)
        gate.yield(Data([1, 0]), captureID: captureID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == nil)
        #expect(gate.rotate() == nil)
        #expect(result.chunks.isEmpty)
        #expect(result.error is MicrophoneCaptureError)
    }

    @Test
    func overflowTerminatesCaptureWithoutReplacingEarlierChunks() async {
        let captureID = UUID()
        let (stream, continuation) = makeStream(capacity: 2)
        let gate = MicrophoneCaptureGate(captureID: captureID, continuation: continuation)
        let accepted = [Data([1, 0]), Data([2, 0])]

        for payload in accepted {
            gate.yield(payload, captureID: captureID)
        }
        gate.yield(Data([3, 0]), captureID: captureID)
        gate.yield(Data([4, 0]), captureID: captureID)
        continuation.finish()
        let result = await drain(stream)

        #expect(gate.currentCaptureID == nil)
        #expect(gate.snapshot() == nil)
        #expect(gate.rotate() == nil)
        #expect(result.chunks.map(\.data) == accepted)
        #expect(result.chunks.map(\.captureID) == [captureID, captureID])
        #expect(result.error is MicrophoneCaptureError)
    }

    private enum CaptureFailure: Error, Equatable {
        case failed
    }

    private func makeStream(capacity: Int) -> (
        AsyncThrowingStream<MicrophoneChunk, Error>,
        AsyncThrowingStream<MicrophoneChunk, Error>.Continuation
    ) {
        AsyncThrowingStream.makeStream(bufferingPolicy: .bufferingOldest(capacity))
    }

    private func drain(_ stream: AsyncThrowingStream<MicrophoneChunk, Error>) async -> (
        chunks: [MicrophoneChunk], error: (any Error)?
    ) {
        var chunks: [MicrophoneChunk] = []
        do {
            for try await chunk in stream {
                chunks.append(chunk)
            }
            return (chunks, nil)
        } catch {
            return (chunks, error)
        }
    }
}
