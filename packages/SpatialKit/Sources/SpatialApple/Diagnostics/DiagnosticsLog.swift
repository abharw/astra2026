import Foundation
import os

public enum DiagnosticLevel: String, Codable, Sendable {
    case debug, info, warning, error
}

public struct DiagnosticEvent: Codable, Sendable, Identifiable {
    public let runID: String
    public let sequence: UInt64
    public let timestamp: String
    public let uptimeMs: Double
    public let level: DiagnosticLevel
    public let component: String
    public let event: String
    public let correlationID: String?
    public let fields: [String: String]

    public var id: String { "\(runID):\(sequence)" }
}

/// Small local flight recorder shared by the product and its Apple adapters.
/// Memory is bounded; ordered disk writes run off the calling/audio thread.
/// Events describe stages and identifiers, never request bodies or audio data.
public final class DiagnosticsLog: @unchecked Sendable {
    public static let shared = DiagnosticsLog()

    public let directoryURL: URL
    public let runID = UUID().uuidString.lowercased()
    private let stateLock = NSLock()
    private let diskQueue = DispatchQueue(label: "com.astra.diagnostics.disk", qos: .utility)
    private let systemLog = Logger(subsystem: "com.astra.spatialdemo", category: "diagnostics")
    private let encoder = JSONEncoder()
    private let formatter = ISO8601DateFormatter()
    private let maximumFileBytes: Int
    private let maximumEvents: Int
    private let emitsSystemLog: Bool
    private var sequence: UInt64 = 0
    private var events: [DiagnosticEvent] = []
    private var persistenceError: String?
    // Only the disk queue owns these two fields.
    private var file: FileHandle?
    private var fileBytes = 0

    public init(
        directoryURL: URL? = nil,
        maximumFileBytes: Int = 1_048_576,
        maximumEvents: Int = 300,
        emitsSystemLog: Bool = true
    ) {
        self.directoryURL = directoryURL ?? Self.defaultDirectory
        self.maximumFileBytes = max(4_096, maximumFileBytes)
        self.maximumEvents = max(1, maximumEvents)
        self.emitsSystemLog = emitsSystemLog
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    public func record(
        _ name: String,
        component: String,
        level: DiagnosticLevel = .info,
        correlationID: String? = nil,
        fields: [String: String] = [:]
    ) {
        stateLock.lock()
        sequence &+= 1
        let event = DiagnosticEvent(
            runID: runID,
            sequence: sequence,
            timestamp: formatter.string(from: Date()),
            uptimeMs: ProcessInfo.processInfo.systemUptime * 1_000,
            level: level,
            component: Self.safe(component, limit: 80),
            event: Self.safe(name, limit: 120),
            correlationID: correlationID.map { Self.safe($0, limit: 160) },
            fields: Self.sanitized(fields)
        )
        events.append(event)
        if events.count > maximumEvents { events.removeFirst(events.count - maximumEvents) }
        let data = (try? encoder.encode(event)).map { $0 + Data([0x0a]) }
        if let data {
            // Enqueue under the same lock as sequence assignment: concurrent
            // callers cannot reverse on-disk event order.
            diskQueue.async { [self] in persist(data) }
        }
        stateLock.unlock()

        if emitsSystemLog, let data {
            let line = String(decoding: data, as: UTF8.self)
            switch level {
            case .debug: systemLog.debug("\(line, privacy: .public)")
            case .info: systemLog.info("\(line, privacy: .public)")
            case .warning: systemLog.warning("\(line, privacy: .public)")
            case .error: systemLog.error("\(line, privacy: .public)")
            }
        }
    }

    public func recentEvents(limit: Int = 200) -> [DiagnosticEvent] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return Array(events.suffix(max(0, limit)))
    }

    public var lastPersistenceError: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return persistenceError
    }

    /// Used only by export/tests, never by camera or audio callbacks.
    public func flush() {
        diskQueue.sync { try? file?.synchronize() }
    }

    public func exportSnapshot() throws -> URL {
        flush()
        return try diskQueue.sync {
            let fm = FileManager.default
            try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
            var combined = Data()
            for name in ["events.previous.jsonl", "events.jsonl"] {
                let url = directoryURL.appending(path: name)
                if fm.fileExists(atPath: url.path) { combined.append(try Data(contentsOf: url)) }
            }
            let destination = directoryURL.appending(path: "diagnostics-export.jsonl")
            try combined.write(to: destination, options: .atomic)
            return destination
        }
    }

    private func persist(_ data: Data) {
        do {
            let fm = FileManager.default
            let current = directoryURL.appending(path: "events.jsonl")
            if file == nil {
                try fm.createDirectory(at: directoryURL, withIntermediateDirectories: true)
                if !fm.fileExists(atPath: current.path) {
                    guard fm.createFile(atPath: current.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown)
                    }
                }
                let opened = try FileHandle(forWritingTo: current)
                file = opened
                fileBytes = Int(try opened.seekToEnd())
            }
            if fileBytes + data.count > maximumFileBytes {
                try file?.close()
                file = nil
                let previous = directoryURL.appending(path: "events.previous.jsonl")
                if fm.fileExists(atPath: previous.path) { try fm.removeItem(at: previous) }
                try fm.moveItem(at: current, to: previous)
                guard fm.createFile(atPath: current.path, contents: nil) else {
                    throw CocoaError(.fileWriteUnknown)
                }
                file = try FileHandle(forWritingTo: current)
                fileBytes = 0
            }
            try file?.write(contentsOf: data)
            fileBytes += data.count
        } catch {
            try? file?.close()
            file = nil
            stateLock.lock()
            persistenceError = Self.safe(error.localizedDescription, limit: 300)
            stateLock.unlock()
        }
    }

    private static var defaultDirectory: URL {
        #if os(iOS)
        let base = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #else
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "AstraSpatial")
        #endif
        return base.appending(path: "AstraDiagnostics", directoryHint: .isDirectory)
    }

    private static func sanitized(_ fields: [String: String]) -> [String: String] {
        let forbidden: Set<String> = [
            "authorization", "apikey", "token", "accesstoken", "sessiontoken",
            "sessionauthtoken", "clientsecret", "cookie", "password", "prompt",
            "transcript", "audio", "pcm", "body", "arguments", "payload", "text",
        ]
        var result: [String: String] = [:]
        for key in fields.keys.sorted().prefix(24) {
            let normalized = key.lowercased().filter(\.isLetter)
            result[safe(key, limit: 80)] = forbidden.contains(normalized)
                ? "[redacted]" : safe(fields[key] ?? "", limit: 512)
        }
        return result
    }

    private static func safe(_ value: String, limit: Int) -> String {
        var result = value
        for pattern in [
            #"(?i)Bearer\s+[^\s\"',}]+"#,
            #"\b(?:sk-(?:proj-)?|ek_)[A-Za-z0-9_-]{12,}"#,
            #"(?i)((?:token|api_key|client_secret|authorization)=)[^&\s]+"#,
        ] {
            result = result.replacingOccurrences(of: pattern, with: "[redacted]", options: .regularExpression)
        }
        return String(result.prefix(limit))
    }
}
