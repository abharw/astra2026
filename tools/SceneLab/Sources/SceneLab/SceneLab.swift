import Foundation
import SpatialCore

/// A small acceptance client using the same reducer as the device. It never renders or claims AR evidence.
@main @MainActor
enum SceneLab {
    static func main() async {
        do { try await run() }
        catch {
            FileHandle.standardError.write(Data("SceneLab: \(error)\n".utf8))
            exit(1)
        }
    }

    private static func run() async throws {
        let args = Array(CommandLine.arguments.dropFirst())
        switch args.first {
        case "seed":
            guard args.count == 2 else { throw LabError.usage }
            let document = try startingRack()
            _ = try SceneState(document: document, sceneId: "seed-validation")
            try write(document, to: args[1])
            print("Wrote authored rack: \(document.nodes.count) nodes")
        case "validate":
            guard args.count == 2 else { throw LabError.usage }
            let document = try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: URL(fileURLWithPath: args[1])))
            _ = try SceneState(document: document, sceneId: "validation")
            print("Valid scene: \(document.nodes.count) nodes, \(document.geometryDefinitions.count) geometry definitions")
        case "live":
            guard args.count == 4 || args.count == 5, let url = URL(string: args[1]) else { throw LabError.usage }
            let document = args.count == 5
                ? try JSONDecoder().decode(SceneDocument.self, from: Data(contentsOf: URL(fileURLWithPath: args[4])))
                : SceneDocument(documentId: "live-\(UUID().uuidString)")
            try await exercise(url: url, prompt: args[2], output: args[3], document: document)
        default: throw LabError.usage
        }
    }

    private static func exercise(url: URL, prompt: String, output: String, document: SceneDocument) async throws {
        var state = try SceneState(document: document, sceneId: UUID().uuidString)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        let session = URLSession(configuration: configuration)
        let socket = session.webSocketTask(with: url)
        socket.maximumMessageSize = 256 * 1024
        socket.resume()
        defer { socket.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        let deadline = Task { try await Task.sleep(for: .seconds(180)); socket.cancel(with: .goingAway, reason: nil) }
        defer { deadline.cancel() }
        let start = ContinuousClock.now
        var receipts: [ApplyReceipt] = []
        var hello: [String: Any] = [
            "type": "session.hello", "protocolVersion": 1, "sessionId": UUID().uuidString,
            "sceneId": state.sceneId, "revision": state.revision, "intentEpoch": state.intentEpoch,
            "sceneSchemaVersions": [1], "geometrySemanticsVersions": [1],
            "capabilities": SceneCapability.allCases.map(\.rawValue)
        ]
        if let token = ProcessInfo.processInfo.environment["SESSION_ACCESS_TOKEN"] { hello["authToken"] = token }
        try await send(hello, through: socket)
        try await sendSnapshot(state, through: socket)
        let requestId = UUID().uuidString
        try await send(["type": "user.request", "requestId": requestId, "text": prompt], through: socket)
        while true {
            let data: Data
            switch try await socket.receive() {
            case let .data(value): data = value
            case let .string(value): data = Data(value.utf8)
            @unknown default: continue
            }
            guard let envelope = try JSONSerialization.jsonObject(with: data) as? [String: Any], let type = envelope["type"] as? String else { throw LabError.invalidResponse }
            if ["generation.begin", "generation.batch", "generation.finish", "scene.patch"].contains(type) {
                let message = try SceneWireDecoder().decodeMessage(from: data)
                let receipt = state.apply(message)
                receipts.append(receipt)
                try await socket.send(.string(String(decoding: JSONEncoder().encode(receipt), as: UTF8.self)))
                try await sendSnapshot(state, through: socket)
                switch receipt {
                case let .scene(value):
                    print("\(type): \(value.status.rawValue), revision \(value.revision)")
                    if let rejection = value.rejection { throw LabError.rejected(rejection.code + ": " + rejection.message) }
                case let .generation(value):
                    print("\(type): \(value.status.rawValue), revision \(value.revision)")
                    if let rejection = value.rejection { throw LabError.rejected(rejection.code + ": " + rejection.message) }
                }
            } else if type == "session.error" {
                throw LabError.rejected("\(envelope["code"] ?? "unknown"): \(envelope["message"] ?? "")")
            } else if type == "session.explanation" {
                let evidence = LiveEvidence(source: "liveAstraHeadlessSwiftReducer", prompt: prompt, elapsed: start.duration(to: .now).description, revision: state.revision, receipts: receipts, explanation: envelope["text"] as? String ?? "", document: state.document)
                try write(evidence, to: output)
                try write(state.document, to: output + ".scene.json")
                print("Live acceptance complete: \(state.document.nodes.count) nodes. Evidence: \(output)")
                return
            }
        }
    }

    private static func sendSnapshot(_ state: SceneState, through socket: URLSessionWebSocketTask) async throws {
        let document = try JSONSerialization.jsonObject(with: JSONEncoder().encode(state.document))
        try await send(["type": "phone.snapshot", "sceneId": state.sceneId, "revision": state.revision, "intentEpoch": state.intentEpoch, "document": document], through: socket)
    }

    private static func send(_ object: [String: Any], through socket: URLSessionWebSocketTask) async throws {
        let text = String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self)
        try await socket.send(.string(text))
    }

    private static func write<T: Encodable>(_ value: T, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private static func startingRack() throws -> SceneDocument {
        try makeDetailedServerRack()
    }
}

private struct LiveEvidence: Encodable {
    let source: String
    let prompt: String
    let elapsed: String
    let revision: UInt64
    let receipts: [ApplyReceipt]
    let explanation: String
    let document: SceneDocument
}

private enum LabError: Error, CustomStringConvertible {
    case usage, invalidResponse, rejected(String)

    var description: String {
        switch self {
        case .usage: "Usage: SceneLab seed OUTPUT | validate SCENE | live WS_URL PROMPT EVIDENCE [STARTING_SCENE]"
        case .invalidResponse: "The service returned an invalid response."
        case let .rejected(reason): reason
        }
    }
}
