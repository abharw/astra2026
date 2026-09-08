import Foundation

enum RealtimeWire {
    static func sessionUpdate() -> [String: Any] {
        [
            "type": "session.update",
            "session": [
                "type": "realtime",
                "output_modalities": ["audio"],
                "instructions": "You are the voice delivery layer for Astra. Do not invent technical explanations or claim scene changes. Speak only when the application explicitly supplies receipt-backed narration.",
                "audio": [
                    "input": [
                        "format": ["type": "audio/pcm", "rate": 24_000],
                        "noise_reduction": ["type": "near_field"],
                        "transcription": ["model": "gpt-live-transcribe"],
                        "turn_detection": [
                            "type": "server_vad",
                            "threshold": 0.5,
                            "prefix_padding_ms": 300,
                            "silence_duration_ms": 450,
                            "create_response": false,
                            "interrupt_response": true,
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
        [
            "type": "input_audio_buffer.append",
            "audio": data.base64EncodedString(),
        ]
    }

    static func speak(_ cue: VoiceNarrationCue) -> [String: Any] {
        [
            "type": "response.create",
            "event_id": "narration_\(cue.requestID)",
            "response": [
                "output_modalities": ["audio"],
                "instructions": "Read the following authoritative Astra explanation exactly as written. Do not add, remove, paraphrase, or answer beyond it:\n\n\(cue.text)",
            ],
        ]
    }

    static func cancelResponse() -> [String: Any] {
        ["type": "response.cancel"]
    }

    static func truncate(itemID: String, contentIndex: Int, audioEndMilliseconds: Int) -> [String: Any] {
        [
            "type": "conversation.item.truncate",
            "item_id": itemID,
            "content_index": contentIndex,
            "audio_end_ms": max(0, audioEndMilliseconds),
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

        private enum CodingKeys: String, CodingKey {
            case value
            case expiresAt = "expires_at"
        }
    }

    let clientSecret: ClientSecret
    let model: String
}
