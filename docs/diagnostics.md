# Diagnostics

The app writes structured JSONL diagnostics through `DiagnosticsLog`, with OSLog mirrors and bounded rotation. The in-app Settings → Diagnostics screen shows recent events and exports a snapshot without exposing credentials or raw audio. The session service writes its own JSONL records under `ASTRA_LOG_DIR`.

Diagnostics are evidence about state transitions, not proof that a physical interaction succeeded. Correlate events by request ID and scene/intent epoch: text or speech submission, Realtime response phases, `ask_astra` execution, service proposal/receipt, native installation, and final text/audio delivery. A stale or mismatched receipt is recorded and cannot release a final response.

The current conversation path is one Realtime session. Typed text or local speech onset binds the authoritative selected node IDs in the app. Realtime is forced to call `ask_astra` exactly once with `{request:string}`; the app executes that call only after a completed response, awaits the terminal scene-service result for the same request ID and epoch, sends `function_call_output`, and requests the final response. The final response is delivered as text for typed turns or audio plus transcript for spoken turns.

The current service uses a fresh HTTP Responses request and one complete `propose_scene` result. PTC, steering, and progressive multi-batch streaming are future experiments. The smoke artifact `evidence/realtime-tools-smoke.json` proves the forced-tool sequence with a synthetic scene result; it does not prove native scene installation, pointing accuracy, microphone quality, or end-to-end physical voice behavior.

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
| Final response | `final_response_completed`, `final_first_audio`, playback completion |

Connection establishment has separate native WebSocket-open, scene handshake, credential HTTP, and Realtime-configuration events. An open socket is not treated as an accepted application session. Errors take display priority over progress, and rejected typed input stays in the composer.

Native logs live in the app's `Documents/AstraDiagnostics`: at most two rotating files of roughly 1 MiB each, plus a generated export snapshot. The in-memory viewer keeps 300 events. Backend logs rotate `astra-session.jsonl` at 2 MiB with one previous file. Backend output also goes to stdout. JSONL timestamps are UTC; native events include monotonic uptime and a process run ID. Cross-machine timestamps are diagnostic approximations, not synchronized latency measurements.

Collect logs from a development device without relying on its network connection:

```sh
python3 scripts/dev-session.py logs --device 'iPad'
python3 scripts/dev-session.py logs --simulator-id 564C0D96-3E0F-491B-8592-910A7DAEECEA
```

Copies go under ignored `runtime/diagnostics`. `dev-session.py serve` sets backend logs under ignored `runtime/logs/backend-8788` and reuses the local access token for the same URL. Use `--rotate-token` only when intentionally replacing it; subsequently relaunch devices to inject the new token. Logs and exported app files must not be committed as raw traces. Check a small evidence summary for scope and secret/content exclusions before adding it to `evidence/`.
