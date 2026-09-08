import Foundation

enum HarnessInputSource: String, Codable, Sendable {
    case syntheticLandmarks

    var displayName: String {
        "Synthetic landmark replay"
    }

    var claim: String {
        "Deterministic mapping and resolver result; no Vision detection, camera, ARKit, or physical-device claim"
    }
}

struct EvidenceEvent: Identifiable, Codable, Sendable, Equatable {
    enum Kind: String, Codable, Sendable {
        case runStarted
        case permission
        case observation
        case targetChanged
        case speechLocked
        case failure
        case runFinished
    }

    let id: UUID
    let kind: Kind
    let timestamp: TimeInterval
    let source: HarnessInputSource
    let caseID: String?
    let detail: String
    let targetNodeID: String?
    let observationAgeMilliseconds: Double?
    let processingMilliseconds: Double?

    init(
        id: UUID = UUID(),
        kind: Kind,
        timestamp: TimeInterval,
        source: HarnessInputSource,
        caseID: String? = nil,
        detail: String,
        targetNodeID: String? = nil,
        observationAgeMilliseconds: Double? = nil,
        processingMilliseconds: Double? = nil
    ) {
        self.id = id
        self.kind = kind
        self.timestamp = timestamp
        self.source = source
        self.caseID = caseID
        self.detail = detail
        self.targetNodeID = targetNodeID
        self.observationAgeMilliseconds = observationAgeMilliseconds
        self.processingMilliseconds = processingMilliseconds
    }
}

struct EvidenceReceipt: Codable, Sendable {
    struct Environment: Codable, Sendable {
        let operatingSystem: String
        let architecture: String
        let harnessBundleVersion: String
        let evidenceBoundary: String
    }

    let schemaVersion: Int
    let runID: UUID
    let startedAt: Date
    let exportedAt: Date
    let activeSource: HarnessInputSource
    let sourceClaim: String
    let environment: Environment
    let events: [EvidenceEvent]
}

enum EvidenceExporter {
    static func data(
        runID: UUID,
        startedAt: Date,
        activeSource: HarnessInputSource,
        events: [EvidenceEvent]
    ) throws -> Data {
        let info = ProcessInfo.processInfo
        let architecture: String
#if arch(arm64)
        architecture = "arm64"
#elseif arch(x86_64)
        architecture = "x86_64"
#else
        architecture = "unknown"
#endif
        let receipt = EvidenceReceipt(
            schemaVersion: 1,
            runID: runID,
            startedAt: startedAt,
            exportedAt: Date(),
            activeSource: activeSource,
            sourceClaim: activeSource.claim,
            environment: .init(
                operatingSystem: info.operatingSystemVersionString,
                architecture: architecture,
                harnessBundleVersion: Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "development",
                evidenceBoundary: "synthetic macOS replay; does not establish Vision detection, camera behavior, RealityKit picking, ARKit tracking, or physical-device 6DoF"
            ),
            events: events
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(receipt)
    }
}
