# Native Realtime voice baseline

`VoiceSession` is an explicit-start native iOS audio path:

1. It asks the local session service for a short-lived Realtime client secret.
2. It opens a direct `URLSessionWebSocketTask` to `gpt-realtime-2.1`.
3. `AVAudioEngine` converts the active microphone route to 24 kHz, mono, little-endian PCM16 and streams it as `input_audio_buffer.append` events.
4. A bounded local PCM onset gate captures the current selection before the audio reaches the network. Server VAD supplies the authoritative turn and item ID but does not let Realtime author a response. Final transcripts are matched to that exact item ID; ambiguous turns are dropped instead of being rebound to a later selection.
5. The app may give `VoiceSession` a receipt-backed Astra explanation. A scene/epoch gate is checked before requesting audio and again for every audio chunk.

The WebSocket baseline deliberately owns playback accounting. When speech interrupts output, it stops `AVAudioPlayerNode` and sends `conversation.item.truncate` at the estimated number of frames actually rendered.

## Current limitations

- OpenAI recommends WebRTC for browser and mobile clients. This implementation uses WebSocket to avoid adding and validating a native WebRTC dependency during the first controlled spike.
- `AVAudioEngine` voice processing is requested on supported routes, but this path does not provide WebRTC congestion control. Echo behavior must be tested on the actual iPad/iPhone and route; headphones are the reliable fallback when system voice processing is unavailable.
- The iOS Simulator may expose no microphone or a route unlike the target device. A simulator failure is reported as unavailable and is not device acceptance evidence.
- Playback cutoff uses the player node's rendered sample timeline. Device tests must verify interruption/truncation under speaker, wired, Bluetooth HFP, route change, and system interruption conditions.
- Audio route and `AVAudioEngineConfigurationChange` events rebuild the graph from the newly reported input format. The observable route summary records port types, hardware input format, and voice-processing availability; continuity still needs device evidence.
- The client secret stays in the ephemeral WebSocket request only. The app never accepts or stores a standard OpenAI API key.
