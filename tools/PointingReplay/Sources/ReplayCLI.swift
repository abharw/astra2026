import Foundation

@main
enum ReplayCLI {
    static func main() throws {
        let arguments = Array(CommandLine.arguments.dropFirst())
        if arguments.contains("--help") || arguments.contains("-h") {
            print(usage)
            return
        }

        let selectedCases: [ReplayCase]
        if let caseID = value(after: "--case", in: arguments) {
            guard let replay = ReplayCase.all.first(where: { $0.id == caseID }) else {
                throw CLIError.unknownCase(caseID)
            }
            selectedCases = [replay]
        } else {
            selectedCases = ReplayCase.all
        }

        let startedAt = Date()
        let runID = UUID()
        let runs = selectedCases.map { ($0, ReplayRunner.run($0)) }
        let failures = validate(runs)
        let events = runs.flatMap { $0.1.events }
        let data = try EvidenceExporter.data(
            runID: runID,
            startedAt: startedAt,
            activeSource: .syntheticLandmarks,
            events: events
        )

        if let outputPath = value(after: "--output", in: arguments) {
            let outputURL = URL(fileURLWithPath: outputPath)
            try data.write(to: outputURL, options: .atomic)
            print("wrote \(outputURL.path)")
        } else {
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }

        if !failures.isEmpty {
            failures.forEach { writeStandardError("FAIL \($0)\n") }
            throw CLIError.assertionsFailed(failures.count)
        }
        for (replay, result) in runs {
            let target = result.speechLock?.selection.nodeID ?? "none"
            writeStandardError("PASS \(replay.id) speechTarget=\(target)\n")
        }
    }

    private static func validate(_ runs: [(ReplayCase, ReplayRunResult)]) -> [String] {
        var failures: [String] = []
        for (replay, result) in runs {
            let actualTarget = result.speechLock?.selection.nodeID
            if actualTarget != replay.expectedSpeechTarget {
                failures.append(
                    "\(replay.id): expected speech target \(replay.expectedSpeechTarget ?? "none"), got \(actualTarget ?? "none")"
                )
            }
            if replay.expectsRejectedObservation,
               !result.events.contains(where: { $0.kind == .failure && $0.detail.contains("mapped to screen") }) {
                failures.append("\(replay.id): expected a rejected stale/out-of-order observation")
            }
        }
        return failures
    }

    private static func value(after flag: String, in arguments: [String]) -> String? {
        guard let index = arguments.firstIndex(of: flag), arguments.indices.contains(index + 1) else {
            return nil
        }
        return arguments[index + 1]
    }

    private static func writeStandardError(_ value: String) {
        FileHandle.standardError.write(Data(value.utf8))
    }

    private static let usage = """
    Usage: astra-pointing-replay [--all] [--case CASE_ID] [--output FILE]

    Runs deterministic synthetic landmarks through SpatialApple's production
    viewport mapping and pointing resolver. Output does not establish Vision,
    camera, ARKit, or physical-device behavior.

    Cases: \(ReplayCase.all.map(\.id).joined(separator: ", "))
    """
}

private enum CLIError: Error, CustomStringConvertible {
    case unknownCase(String)
    case assertionsFailed(Int)

    var description: String {
        switch self {
        case .unknownCase(let value): "Unknown replay case: \(value)"
        case .assertionsFailed(let count): "\(count) replay assertion(s) failed"
        }
    }
}
