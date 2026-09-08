import Foundation
import SpatialCore
import Darwin

/// Offline NDJSON access to the same reducer used by the native client.
enum ReducerBridge {
    static func run() {
        var input = BoundedJSONLines(handle: .standardInput)
        var session = ReducerSession()
        do {
            while let line = try input.next() {
                let response = switch line {
                case .data(let data): session.respond(to: data)
                case .tooLarge: BridgeResponse.failure(id: "", code: "request_too_large")
                }
                try write(response)
            }
        } catch {
            // I/O failures must never expose payloads or Foundation error details.
            try? write(BridgeResponse.failure(id: "", code: "io_failed"))
            exit(1)
        }
    }

    private static func write(_ response: BridgeResponse) throws {
        var data = try JSONEncoder().encode(response)
        data.append(0x0A)
        try FileHandle.standardOutput.write(contentsOf: data)
    }
}

private struct ReducerSession {
    private var state: SceneState?

    mutating func respond(to data: Data) -> BridgeResponse {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let request = object as? [String: Any],
              let id = request["id"] as? String,
              !id.isEmpty, id.utf8.count <= 128
        else { return .failure(id: "", code: "invalid_request") }
        guard let command = request["command"] as? String else {
            return .failure(id: id, code: "invalid_request")
        }

        if command == "initialize" {
            guard Set(request.keys) == ["id", "command", "document", "sceneId"],
                  let sceneID = request["sceneId"] as? String,
                  let document = request["document"] as? [String: Any]
            else { return .failure(id: id, code: "invalid_request") }
            do {
                let documentData = try JSONSerialization.data(withJSONObject: document)
                let decoded = try JSONDecoder().decode(SceneDocument.self, from: documentData)
                let initialized = try SceneState(document: decoded, sceneId: sceneID)
                state = initialized
                return .success(id: id, state: initialized)
            } catch {
                return .failure(id: id, code: "invalid_document")
            }
        }

        let allowedKeys: Set<String>
        switch command {
        case "apply": allowedKeys = ["id", "command", "message"]
        case "advanceIntent", "undo", "snapshot": allowedKeys = ["id", "command"]
        default: return .failure(id: id, code: "unknown_command")
        }
        guard Set(request.keys) == allowedKeys else {
            return .failure(id: id, code: "invalid_request")
        }
        guard var current = state else {
            return .failure(id: id, code: "not_initialized")
        }

        var receipt: ApplyReceipt?
        var undoApplied: Bool?
        switch command {
        case "apply":
            guard let message = request["message"] as? [String: Any] else {
                return .failure(id: id, code: "invalid_request")
            }
            do {
                let messageData = try JSONSerialization.data(withJSONObject: message)
                let decoded = try SceneWireDecoder().decodeMessage(from: messageData)
                receipt = current.apply(decoded)
            } catch SceneWireError.messageTooLarge {
                return .failure(id: id, code: "wire_message_too_large")
            } catch {
                return .failure(id: id, code: "invalid_wire_message")
            }
        case "advanceIntent":
            guard current.intentEpoch < SceneState.maximumWireInteger else {
                return .failure(id: id, code: "intent_epoch_exhausted")
            }
            current.advanceIntentEpoch()
        case "undo":
            let result = current.undo(requestId: id)
            receipt = .scene(result)
            undoApplied = result.status == .installed
        case "snapshot": break
        default: return .failure(id: id, code: "unknown_command")
        }
        state = current
        return .success(id: id, state: current, receipt: receipt, undoApplied: undoApplied)
    }
}

private struct BridgeResponse: Encodable {
    let id: String
    let ok: Bool
    var sceneId: String?
    var revision: UInt64?
    var intentEpoch: UInt64?
    var document: SceneDocument?
    var capabilities: [String]?
    var receipt: ApplyReceipt?
    var undoApplied: Bool?
    var code: String?

    static func success(
        id: String, state: SceneState, receipt: ApplyReceipt? = nil, undoApplied: Bool? = nil
    ) -> Self {
        Self(
            id: id, ok: true, sceneId: state.sceneId, revision: state.revision,
            intentEpoch: state.intentEpoch, document: state.document,
            capabilities: SceneCapability.allCases.map(\.rawValue),
            receipt: receipt, undoApplied: undoApplied
        )
    }

    static func failure(id: String, code: String) -> Self {
        Self(id: id, ok: false, code: code)
    }
}

/// Reads in fixed chunks and drains an oversized line without retaining it.
private struct BoundedJSONLines {
    enum Line {
        case data(Data)
        case tooLarge
    }

    private enum ReadError: Error { case failed }

    private static let maximumLineBytes = 1_024 * 1_024
    let handle: FileHandle
    private var chunk = [UInt8](repeating: 0, count: 8_192)
    private var availableBytes = 0
    private var offset = 0

    init(handle: FileHandle) {
        self.handle = handle
    }

    mutating func next() throws -> Line? {
        var line = Data()
        var tooLarge = false
        while true {
            if offset == availableBytes {
                // FileHandle.read(upToCount:) may wait to fill its buffer on a pipe.
                // One bounded POSIX read lets each flushed command receive a response.
                let descriptor = handle.fileDescriptor
                let count = chunk.withUnsafeMutableBytes { bytes in
                    Darwin.read(descriptor, bytes.baseAddress, bytes.count)
                }
                if count < 0 {
                    if errno == EINTR { continue }
                    throw ReadError.failed
                }
                availableBytes = count
                offset = 0
                if count == 0 {
                    guard tooLarge || !line.isEmpty else { return nil }
                    return tooLarge ? .tooLarge : .data(line)
                }
            }

            let newline = chunk[offset..<availableBytes].firstIndex(of: 0x0A)
            let end = newline ?? availableBytes
            if !tooLarge {
                if line.count + end - offset <= Self.maximumLineBytes {
                    line.append(contentsOf: chunk[offset..<end])
                } else {
                    line.removeAll(keepingCapacity: false)
                    tooLarge = true
                }
            }
            offset = newline.map { chunk.index(after: $0) } ?? end
            if newline != nil { return tooLarge ? .tooLarge : .data(line) }
        }
    }
}
