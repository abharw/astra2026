import Foundation
import SpatialApple
import Testing

@Test func diagnosticsRedactSecretsAndConversationContent() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticsLog(directoryURL: directory, emitsSystemLog: false)
    log.record("request.failed", component: "transport", correlationID: "request-42", fields: [
        "authorization": "Bearer private-token-value",
        "client_secret": "private-credential",
        "transcript": "private conversation",
        "arguments": "private tool arguments",
        "error": "Rejected Bearer hidden-access-value from ?token=hidden-query-value",
        "provider_detail": "sk-proj-hiddenproviderkey12345",
        "bytes": "512",
    ])
    let data = try Data(contentsOf: log.exportSnapshot())
    let text = String(decoding: data, as: UTF8.self)
    for secret in ["private-token", "private-credential", "private conversation", "private tool", "hidden-access", "hidden-query", "hiddenproviderkey"] {
        #expect(!text.contains(secret))
    }
    let event = try #require(log.recentEvents().first)
    #expect(event.correlationID == "request-42")
    #expect(event.fields["bytes"] == "512")
    #expect(event.fields["arguments"] == "[redacted]")
    #expect(log.lastPersistenceError == nil)
}

@Test func diagnosticsPreserveConcurrentOrderAndBoundMemory() async throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticsLog(directoryURL: directory, maximumEvents: 9, emitsSystemLog: false)
    await withTaskGroup(of: Void.self) { group in
        for index in 0..<150 {
            group.addTask {
                log.record("step", component: "test", fields: ["index": String(index)])
            }
        }
    }
    let data = try Data(contentsOf: log.exportSnapshot())
    let events = try data.split(separator: 0x0a).map { try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0)) }
    #expect(events.count == 150)
    #expect(events.map(\.sequence) == Array(UInt64(1)...150))
    #expect(log.recentEvents().count == 9)
    #expect(log.recentEvents().map(\.sequence) == Array(UInt64(142)...150))
}

@Test func diagnosticsRotateWithoutLosingLatestFailure() throws {
    let directory = FileManager.default.temporaryDirectory.appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: directory) }
    let log = DiagnosticsLog(directoryURL: directory, maximumFileBytes: 4_096, emitsSystemLog: false)
    for _ in 0..<100 { log.record("progress", component: "test", fields: ["status": String(repeating: "x", count: 200)]) }
    log.record("connection.failed", component: "test", level: .error)
    let export = try Data(contentsOf: log.exportSnapshot())
    let events = try export.split(separator: 0x0a).map { try JSONDecoder().decode(DiagnosticEvent.self, from: Data($0)) }
    #expect(events.count < 100)
    #expect(events.last?.event == "connection.failed")
    #expect(events.map(\.sequence) == events.map(\.sequence).sorted())
    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    #expect(Set(names) == ["events.jsonl", "events.previous.jsonl", "diagnostics-export.jsonl"])
    #expect(log.lastPersistenceError == nil)
}
