import Foundation

/// Resolves screen-aligned hand observations into temporary hover feedback and
/// immutable speech-start selections. It owns no AR session, scene revision, or
/// entity tree; callers provide the native hit test that maps a screen point to a
/// semantic node ID.
public struct PointingResolver: Sendable {
    public struct Configuration: Sendable, Hashable {
        public var minimumConfidence: Double
        public var cursorSmoothingFactor: Double
        public var stableDwellDuration: TimeInterval
        public var stableMovementRadius: Double
        public var maximumObservationAge: TimeInterval

        public init(
            minimumConfidence: Double = 0.55,
            cursorSmoothingFactor: Double = 0.35,
            stableDwellDuration: TimeInterval = 0.12,
            stableMovementRadius: Double = 28,
            maximumObservationAge: TimeInterval = 0.35
        ) {
            self.minimumConfidence = minimumConfidence
            self.cursorSmoothingFactor = cursorSmoothingFactor
            self.stableDwellDuration = stableDwellDuration
            self.stableMovementRadius = stableMovementRadius
            self.maximumObservationAge = maximumObservationAge
        }
    }

    public private(set) var configuration: Configuration

    private var lastTimestamp: TimeInterval?
    private var cursor: PointingCursor?
    private var hover: PointingHover?
    private var stableHover: PointingHover?
    private var candidate: Candidate?
    private var confirmedSelection: PointingSelection?
    private var activeSpeechLock: PointingSpeechLock?
    private var pointingAttemptActive = false

    public init(configuration: Configuration = .init()) {
        self.configuration = configuration
    }

    /// Updates local cursor and hover state. `hitTest` must only query native
    /// render state; it must not mutate a scene revision.
    @discardableResult
    public mutating func ingest(
        _ observation: PointingScreenObservation,
        now: TimeInterval,
        hitTest: (PointingScreenPoint) -> PointingTarget?
    ) -> PointingResolverUpdate {
        guard accepts(observation, now: now) else {
            return update(rejectedObservation: true)
        }

        lastTimestamp = observation.timestamp
        pointingAttemptActive = true

        guard observation.confidence >= sanitizedMinimumConfidence else {
            clearTrackingState()
            return update()
        }

        let smoothedPoint: PointingScreenPoint
        if let cursor {
            let factor = sanitizedSmoothingFactor
            smoothedPoint = PointingScreenPoint(
                x: cursor.point.x + (observation.point.x - cursor.point.x) * factor,
                y: cursor.point.y + (observation.point.y - cursor.point.y) * factor
            )
        } else {
            smoothedPoint = observation.point
        }

        let nextCursor = PointingCursor(
            point: smoothedPoint,
            confidence: observation.confidence,
            timestamp: observation.timestamp
        )
        cursor = nextCursor

        guard let target = hitTest(smoothedPoint) else {
            hover = nil
            candidate = nil
            stableHover = nil
            return update()
        }

        let isStable = advanceCandidate(target: target, cursor: nextCursor)
        let nextHover = PointingHover(target: target, cursor: nextCursor, isStable: isStable)
        hover = nextHover
        stableHover = isStable ? nextHover : nil
        return update()
    }

    /// Expires transient tracking when no newer camera result has arrived.
    /// A confirmed selection and an active speech lock remain intact.
    @discardableResult
    public mutating func expire(at now: TimeInterval) -> PointingResolverUpdate {
        guard let lastTimestamp, now - lastTimestamp > sanitizedMaximumObservationAge else {
            return update()
        }
        clearTrackingState()
        pointingAttemptActive = false
        return update()
    }

    /// Handles a detector-confirmed hand loss. The timestamp must share the
    /// frame clock used for hand observations.
    @discardableResult
    public mutating func handLost(at timestamp: TimeInterval) -> PointingResolverUpdate {
        guard lastTimestamp.map({ timestamp > $0 }) ?? true else {
            return update(rejectedObservation: true)
        }
        lastTimestamp = timestamp
        clearTrackingState()
        pointingAttemptActive = false
        return update()
    }

    /// Clears only transient cursor and hover state. A deliberately confirmed
    /// selection and an in-flight speech lock remain valid until their owner
    /// explicitly ends them.
    @discardableResult
    public mutating func clearTransientTracking() -> PointingResolverUpdate {
        lastTimestamp = nil
        pointingAttemptActive = false
        clearTrackingState()
        return update()
    }

    /// Clears all pointing state when the accepted scene identity changes. A
    /// selection or speech lock from the prior scene must never be reused.
    @discardableResult
    public mutating func resetForSceneChange() -> PointingResolverUpdate {
        lastTimestamp = nil
        pointingAttemptActive = false
        clearTrackingState()
        confirmedSelection = nil
        activeSpeechLock = nil
        return update()
    }

    /// Explicitly preserves a fresh stable hover as a local selection. This is
    /// available for a later optional pinch confirmation, but pinch is not needed
    /// for the first pointing-and-speak interaction.
    @discardableResult
    public mutating func confirmStableTarget(
        sceneID: String,
        at now: TimeInterval,
        selectionEventID: UUID = UUID()
    ) -> PointingSelection? {
        guard let stableHover, isFresh(stableHover.cursor.timestamp, at: now) else {
            return nil
        }

        let selection = PointingSelection(
            sceneID: sceneID,
            nodeID: stableHover.target.nodeID,
            selectionEventID: selectionEventID,
            observationTimestamp: stableHover.cursor.timestamp
        )
        confirmedSelection = selection
        return selection
    }

    /// Captures the fresh stable target exactly when local speech begins.
    ///
    /// If a hand is currently being tracked but cannot resolve a stable target,
    /// this deliberately returns `nil` rather than falling back to an older
    /// selection. A previously confirmed selection is usable only after pointing
    /// is no longer active.
    @discardableResult
    public mutating func beginSpeech(
        sceneID: String,
        at now: TimeInterval,
        selectionEventID: UUID = UUID(),
        speechLockID: UUID = UUID()
    ) -> PointingSpeechLock? {
        let selection: PointingSelection?
        if let stableHover, isFresh(stableHover.cursor.timestamp, at: now) {
            selection = PointingSelection(
                sceneID: sceneID,
                nodeID: stableHover.target.nodeID,
                selectionEventID: selectionEventID,
                observationTimestamp: stableHover.cursor.timestamp
            )
        } else if !pointingAttemptActive,
                  let confirmedSelection,
                  confirmedSelection.sceneID == sceneID {
            selection = confirmedSelection
        } else {
            selection = nil
        }

        guard let selection else {
            return nil
        }

        confirmedSelection = selection
        let speechLock = PointingSpeechLock(
            speechLockID: speechLockID,
            selection: selection,
            lockedAt: now
        )
        activeSpeechLock = speechLock
        return speechLock
    }

    /// Clears the in-flight speech lock only when the matching request finishes.
    /// Pointer updates never change an existing lock.
    @discardableResult
    public mutating func endSpeech(lockID: UUID) -> PointingResolverUpdate {
        if activeSpeechLock?.speechLockID == lockID {
            activeSpeechLock = nil
        }
        return update()
    }

    @discardableResult
    public mutating func clearConfirmedSelection() -> PointingResolverUpdate {
        confirmedSelection = nil
        return update()
    }

    private mutating func advanceCandidate(target: PointingTarget, cursor: PointingCursor) -> Bool {
        guard let candidate else {
            self.candidate = Candidate(target: target, beganAt: cursor.timestamp, anchor: cursor.point)
            return false
        }

        guard candidate.target == target,
              candidate.anchor.distance(to: cursor.point) <= sanitizedStableMovementRadius else {
            self.candidate = Candidate(target: target, beganAt: cursor.timestamp, anchor: cursor.point)
            return false
        }

        return cursor.timestamp - candidate.beganAt >= sanitizedStableDwellDuration
    }

    private mutating func clearTrackingState() {
        cursor = nil
        hover = nil
        stableHover = nil
        candidate = nil
    }

    private func accepts(_ observation: PointingScreenObservation, now: TimeInterval) -> Bool {
        guard observation.point.x.isFinite,
              observation.point.y.isFinite,
              observation.confidence.isFinite,
              observation.timestamp.isFinite,
              observation.timestamp >= 0,
              now >= observation.timestamp,
              now - observation.timestamp <= sanitizedMaximumObservationAge else {
            return false
        }
        return lastTimestamp.map { observation.timestamp > $0 } ?? true
    }

    private func isFresh(_ timestamp: TimeInterval, at now: TimeInterval) -> Bool {
        now >= timestamp && now - timestamp <= sanitizedMaximumObservationAge
    }

    private var sanitizedMinimumConfidence: Double {
        min(max(configuration.minimumConfidence, 0), 1)
    }

    private var sanitizedSmoothingFactor: Double {
        min(max(configuration.cursorSmoothingFactor, 0), 1)
    }

    private var sanitizedStableDwellDuration: TimeInterval {
        max(configuration.stableDwellDuration, 0)
    }

    private var sanitizedStableMovementRadius: Double {
        max(configuration.stableMovementRadius, 0)
    }

    private var sanitizedMaximumObservationAge: TimeInterval {
        max(configuration.maximumObservationAge, 0)
    }

    private func update(rejectedObservation: Bool = false) -> PointingResolverUpdate {
        PointingResolverUpdate(
            cursor: cursor,
            hover: hover,
            stableHover: stableHover,
            confirmedSelection: confirmedSelection,
            activeSpeechLock: activeSpeechLock,
            rejectedObservation: rejectedObservation
        )
    }
}

private struct Candidate: Sendable {
    let target: PointingTarget
    let beganAt: TimeInterval
    let anchor: PointingScreenPoint
}
