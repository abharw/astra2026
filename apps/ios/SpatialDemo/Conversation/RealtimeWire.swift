import Foundation

enum RealtimeWire {
    static func sessionUpdate() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": "You are Astra's conversation layer. For each user turn, call ask_astra exactly once. Never claim a scene changed before the tool result. After the tool result, accurately present its explanation or error without inventing state.",
                "tools": [[
                    "type": "function",
                    "name": "ask_astra",
                    "description": "Execute the user's request against Astra's scene agent. Call exactly once per user turn.",
                    "parameters": [
                        "type": "object",
                        "properties": [
                            "request": [
                                "type": "string",
                                "description": "The user's scene request, preserving their intent and relevant detail.",
                            ],
                        ],
                        "required": ["request"],
                        "additionalProperties": false,
                    ],
                ]],
                "tool_choice": "auto",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": "gpt-live-transcribe"],
                        "turn_detection": [
                            "type": "server_vad", "threshold": 0.5,
                            "prefix_padding_ms": 300, "silence_duration_ms": 450,
                            "create_response": false, "interrupt_response": true,
                        ],
                    ],
                    "output": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "voice": "marin",
                    ],
                ],
            ],
        ]
    }

    static func appendAudio(_ data: Data) -> [String: Any] {
        ["type": "input_audio_buffer.append", "audio": data.base64EncodedString()]
    }

    static func textInput(_ text: String, eventID: String) -> [String: Any] {
        [
            "type": "conversation.item.create",
            "event_id": eventID,
            "item": [
                "type": "message", "role": "user",
                "content": [["type": "input_text", "text": text]],
            ],
        ]
    }

    static func toolResponse(generation: Int, requestID: String, source: RealtimeInputSource) -> [String: Any] {
        [
            "type": "response.create",
            "event_id": "turn_\(generation)_tool",
            "response": [
                "output_modalities": ["text"],
                "tool_choice": ["type": "function", "name": "ask_astra"],
                "metadata": [
                    "generation": String(generation),
                    "request_id": requestID,
                    "phase": "tool",
                    "source": source.rawValue,
                ],
            ],
        ]
    }

    static func functionOutput(callID: String, result: RealtimeSceneToolResult) throws -> [String: Any] {
        let data = try JSONEncoder().encode(result)
        guard let output = String(data: data, encoding: .utf8) else { throw VoiceSessionError.invalidToolCall }
        return [
            "type": "conversation.item.create",
            "item": ["type": "function_call_output", "call_id": callID, "output": output],
        ]
    }

    static func finalResponse(
        generation: Int,
        requestID: String,
        source: RealtimeInputSource,
        result: RealtimeSceneToolResult
    ) -> [String: Any] {
        [
            "type": "response.create",
            "event_id": "turn_\(generation)_final",
            "response": [
                "output_modalities": source == .voice ? ["audio"] : ["text"],
                "tool_choice": "none",
                "instructions": finalInstructions(for: result),
                "metadata": [
                    "generation": String(generation),
                    "request_id": requestID,
                    "phase": "final",
                    "source": source.rawValue,
                ],
            ],
        ]
    }

    private static func finalInstructions(for result: RealtimeSceneToolResult) -> String {
        let presentation = "Use only the latest ask_astra function output. Present its explanation clearly in two to four concise sentences, speaking directly as Astra. If clarification is needed, ask the question directly; do not refer to another model or say that it needs clarification. Do not mention internal IDs, receipts, tool calls, or protocol details."
        switch result.outcome {
        case .confirmedInstalled:
            return "The trusted app result confirms that the requested edit is installed in the scene. Describe it as completed. Installation does not prove that a part is visible in the current camera view. If the explanation uses pre-install words such as proposal, proposed, would, could, or recommendation for that edit, rephrase them to the actual installed state. Do not call the installed edit a proposal. \(presentation)"
        case .completedNoChange:
            return "The trusted app result completed without installing a scene edit. Treat this as a read-only answer or a request that required no visual change. Do not claim that anything was added, removed, moved, highlighted, or otherwise changed. \(presentation)"
        case .failed:
            return "The request could not finish successfully. Briefly explain the reported error. A timeout or lost connection can leave an edit's outcome unconfirmed; do not claim that the scene changed or that every change was rolled back unless the result explicitly establishes it. \(presentation)"
        case .cancelled:
            return "The request was cancelled. Cancellation stops further work but does not by itself undo already installed edits. Do not claim a new edit or a rollback that the result does not establish. \(presentation)"
        case .unknown:
            return "The trusted app result has an unknown outcome. Say that the result could not be confirmed. Do not claim any edit or visible result. \(presentation)"
        }
    }

    static func cancelResponse(responseID: String? = nil) -> [String: Any] {
        var event: [String: Any] = ["type": "response.cancel"]
        if let responseID { event["response_id"] = responseID }
        return event
    }

    static func truncate(itemID: String, contentIndex: Int, audioEndMilliseconds: Int) -> [String: Any] {
        [
            "type": "conversation.item.truncate", "item_id": itemID,
            "content_index": contentIndex, "audio_end_ms": max(0, audioEndMilliseconds),
        ]
    }

    static func text(from message: URLSessionWebSocketTask.Message) -> String? {
        switch message {
        case let .string(text): text
        case let .data(data): String(data: data, encoding: .utf8)
        @unknown default: nil
        }
    }

    static func encode(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object)
        guard let text = String(data: data, encoding: .utf8) else {
            throw VoiceSessionError.realtime("Could not encode an outgoing event.")
        }
        return text
    }
}

struct RealtimeClientSecretResponse: Decodable, Sendable {
    struct ClientSecret: Decodable, Sendable {
        let value: String
        let expiresAt: TimeInterval
        private enum CodingKeys: String, CodingKey { case value; case expiresAt = "expires_at" }
    }
    let clientSecret: ClientSecret
    let model: String
}
