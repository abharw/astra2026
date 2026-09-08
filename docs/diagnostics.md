# Diagnostics

The app writes structured JSONL diagnostics through `DiagnosticsLog`, with OSLog mirrors and bounded rotation. The in-app Settings → Diagnostics screen shows recent events and exports a snapshot without exposing credentials or raw audio. The session service writes its own JSONL records under `ASTRA_LOG_DIR`.

Diagnostics are evidence about state transitions, not proof that a physical interaction succeeded. Correlate events by request ID and scene/intent epoch: text or speech submission, Realtime response phases, `ask_astra` execution, service proposal/receipt, native installation, and final text/audio delivery. A stale or mismatched receipt is recorded and cannot release a final response.

The current conversation path is one Realtime session. Typed text or local speech onset binds the authoritative selected node IDs in the app. Local onset only records a selection hint; validated server VAD authorizes interruption, and the committed audio item starts the voice turn. Realtime is forced to call `ask_astra` once with `{request:string}`. The app executes only a completed, matching tool response, awaits the terminal scene-service result, and returns `function_call_output` for that exact call. Only the still-active turn requests a final text or spoken response. A superseded tool's actual terminal result can still return on the same live connection (`superseded_tool_output_returned`); this does not claim durable delivery after disconnect. See the [conversation implementation](../app/SpatialDemo/Conversation/README.md).

The current service uses a fresh HTTP Responses request and one complete `propose_scene` result. PTC, steering, and progressive multi-batch streaming are future experiments. The smoke artifact `docs/evidence/realtime-tools-smoke.json` proves the forced-tool sequence with a synthetic scene result; it does not prove native scene installation, pointing accuracy, microphone quality, or end-to-end physical voice behavior.

When a request appears stuck, inspect the exported event sequence before changing UI behavior. A disconnected submission, missing `response.done`, tool-call argument mismatch, deadline expiry, stale scene/epoch fence, or final response rejection should each be visible as a distinct event. Do not infer success from a spinner or a single provider log line.

## Find a stalled turn

Open Connection settings → Diagnostics. Match the local `turn_…` request ID across these stages:

| Stage | Useful events |
| --- | --- |
| UI admission | `text.submitted` or `text.rejected_offline` |
| Realtime | `typed_turn_sent`, `response_created`, `ask_astra_started` |
| Scene service | `user_request_admitted`, `astra_fetch_start`, provider `fetch_status`, `normalize_repair`, `outgoing_batch` |
| Device | `native.prepare_finished`, `native.installed`, `receipt.created`, `explanation.accepted` |
| Tool return | `tool.finished`, `ask_astra_completed` |
| Final response | `final_response_completed`, `final_first_audio`, `final_playback_completed` |

Connection establishment has separate native WebSocket-open, scene handshake, credential HTTP, and Realtime-configuration events. An open socket is not treated as an accepted application session. Errors take display priority over progress, and rejected typed input stays in the composer.

## Find missing microphone input or speech output

Follow the native pipeline in order. A permission grant or `audio_started` alone does not establish that audio samples reached Realtime.

| Boundary | Evidence and interpretation |
| --- | --- |
| Permission and graph | `microphone_permission_resolved` with `granted`, then `audio_session_configured`, `audio_graph_ready`, and `audio_started`; inspect route, interruption, and engine-recovery events if capture stops. |
| Native tap → conversion | `voice.audio` → `microphone_capture_summary` reports `tap_buffer_count`/`tap_frame_count`, `converted_buffer_count`/`converted_frame_count`, and empty/failed/stale conversion counts. The timer emits even with zero callbacks. Native tap and node output-format fields describe the device route; converted output is always 24 kHz mono signed PCM16. |
| Stream → session consumer | `realtime.session` → `microphone_pcm_summary` counts admitted buffers, frames, and bytes. The stream has eight slots, each at most 32 KiB, and one consumer. Overflow or an oversized chunk produces `microphone_failed`; capture UUID checks reject obsolete buffers. |
| Consumer → WebSocket | `realtime_send_queue_summary` reports outbound pressure; `realtime_receive_summary` and `realtime_event_received` show incoming traffic. Transport summaries are traffic-triggered, unlike the capture timer. They do not acknowledge every audio append. |
| Capture reset and VAD | `input_audio_clear_sent` records the serialized audio clock and capture floor; `input_audio_clear_acknowledged` reopens input. Compare `local_speech_onset`, `remote_speech_bound`, `remote_speech_ignored`, and `remote_speech_binding_missing`. The bound event's `binding_source` distinguishes a local onset from capture-time selection history. Server timestamps and the current capture UUID fence stale events; local energy alone cannot cancel a turn. |
| Speech turn | `voice_turn_committed` precedes the forced tool response. `transcription_completed` means a matching transcript was accepted; a raw `realtime_event_received` transcription event only means it arrived. |
| Audible response | Follow `ask_astra_completed` → `final_first_audio` → `final_response_completed` → `final_playback_completed`. `playback_interrupted`, `output_audio_ignored`, and `playback_completion_ignored` explain interrupted or obsolete output. Counts and playback callbacks do not prove intelligibility or that a person heard the reply. |

Raw tap/conversion counters are updated inside nonisolated `Sendable` helpers; formatting and logging happen on a timer outside the audio callback. Compare adjacent stages to distinguish no device buffers, unsuccessful conversion, rejected old capture, transport delay, and missing turn admission. The implementation keeps server VAD enabled with automatic response creation and interruption both disabled; [Realtime documents this client-controlled response mode](https://developers.openai.com/api/docs/guides/realtime-conversations#keep-vad-but-disable-automatic-responses).

Physical iPhone run `0dec75e8-e31f-4ce2-9198-9403633ed35e` on 2026-09-08 recorded 75 tap buffers / 360,000 frames at 48 kHz, 179,704 converted frames at 24 kHz, and zero empty, failed, or stale conversions. Two server speech commits and two provider transcription-completion events arrived. The trace is local-only at `.local/diagnostics/audio-raw-20260908T231331Z/events.jsonl`. That run exposed local-onset cancellation before the tool call; it does not accept the subsequent interruption fix or prove a complete physical spoken reply.

## Storage and collection

Native logs live in the app's `Documents/AstraDiagnostics`: at most two rotating files of roughly 1 MiB each, plus a generated export snapshot. The in-memory viewer keeps 300 events. Backend logs rotate `astra-session.jsonl` at 2 MiB with one previous file. Backend output also goes to stdout. JSONL timestamps are UTC; native events include monotonic uptime and a process run ID. Cross-machine timestamps are diagnostic approximations, not synchronized latency measurements.

Native records have a lock-ordered sequence number and write to disk on a serial utility queue, with OSLog mirrors; they are not automatically uploaded. Callers log counts, IDs, and state rather than raw PCM, transcripts, prompts, or credentials. The recorder also bounds fields and redacts known sensitive keys and credential patterns; this is not a general-purpose scrubber for arbitrary content.

Collect logs from a development device without relying on its network connection:

```sh
python3 tools/dev-session.py logs --device 'iPad'
python3 tools/dev-session.py logs --simulator-id 564C0D96-3E0F-491B-8592-910A7DAEECEA
```

Copies go under ignored `.local/diagnostics`. `dev-session.py serve` sets backend logs under ignored `.local/logs/backend-8788` and reuses the local access token for the same URL. Use `--rotate-token` only when intentionally replacing it; subsequently relaunch devices to inject the new token. Logs and exported app files must not be committed as raw traces. Check a small evidence summary for scope and secret/content exclusions before adding it to `docs/evidence/`.
