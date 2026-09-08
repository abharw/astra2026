# Realtime conversation

`RealtimeSession` owns one native WebSocket conversation for typed text and speech. `DemoSessionModel` supplies selection snapshots and an asynchronous scene-tool executor; this directory has no server-rack operations or RealityKit dependency.

1. **Connect** obtains an ephemeral credential from `POST /realtime/client-secret` and waits for `session.updated`. This does not request microphone permission or start audio capture.
2. **Typed input** sends a user `conversation.item.create` with `input_text`. **Voice input** streams 24 kHz PCM from `AudioIOController`; local onset captures selection, and the server's committed audio item starts a turn. Transcription is display data, not a second scene request.
3. An initial `response.create` forces one `ask_astra` function with `{request: string}`. Initial text preambles are hidden. Only a completed `response.done` with matching turn metadata and valid arguments can invoke the executor.
4. The executor calls the existing Astra scene service. The service uses `gpt-6-astra` to author a complete `propose_scene` result. `SceneController.execute` waits for matching receipts and explanation, or returns a terminal failure/cancellation.
5. The exact `call_id` receives a `function_call_output` containing status, request ID, scene/revision/epoch, proposal IDs, and explanation/error. A second `response.create` disables tools and requests text for a typed turn or audio plus transcript for a spoken turn.

The native client owns WebSocket ordering, timeouts, response identity, cancellation, and playback truncation. Microphone capture is explicitly enabled. AVAudioEngine uses voice processing where available; `PCMCodec` converts between device audio and the wire format. Onset, route changes, queue counts, function calls, and completion are logged without recording raw audio or text. See [diagnostics](../../../docs/diagnostics.md).

The forced one-tool policy is deliberately small: all scene questions go through Astra and the acknowledged scene, and each user turn permits one scene execution. Realtime handles conversation context and reformulates the request; its function arguments do not supply authoritative node IDs, scene versions, or installation claims. This is one conversational interface with a separate scene executor, not one model or one physical network connection.

A live [provider smoke](../../../docs/evidence/realtime-tools-smoke.json) tested forced tools, echoed metadata, and final text/audio in one Realtime session using synthetic scene results. Native end-to-end and physical audio evidence are listed separately in [acceptance evidence](../../../docs/evidence/README.md).

Sources: [Realtime conversations and function calling](https://developers.openai.com/api/docs/guides/realtime-conversations#function-calling), [client events](https://developers.openai.com/api/reference/resources/realtime/client-events#response.create), [response completion](https://developers.openai.com/api/reference/resources/realtime/server-events#response.done). Argument-completion events alone are insufficient: they also arrive for interrupted/incomplete responses.
