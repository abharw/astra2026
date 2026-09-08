# Astra session service

This is the network service between the native app and OpenAI. It can run on the development Mac or a WebSocket-capable host. It uses `gpt-6-astra` through the Responses API to author a bounded scene proposal, then sends only portable scene envelopes to the device. `gpt-realtime-2.1` carries native text and voice turns; this service mints its short-lived credential and never relays raw audio.

## Run

From the repository root, enter the backend and install dependencies once:

```sh
cd backend
npm ci
```

Run the loopback-only development service with Doppler. `OPENAI_API_KEY` must come from the Doppler `backend/dev` config; it is never read from a file, sent to the app, or logged.

```sh
doppler run --project backend --config dev --only-secrets OPENAI_API_KEY -- npm start
```

The default endpoints are `GET http://127.0.0.1:8787/health` and `ws://127.0.0.1:8787/session`. `ASTRA_SESSION_HOST` and `ASTRA_SESSION_PORT` configure the listener. A non-loopback host requires `SESSION_ACCESS_TOKEN`; native supplies it in `session.hello.authToken` and the Authorization bearer header for realtime credentials and illustration downloads. The health response intentionally reports only whether an OpenAI credential exists.

```sh
npm run typecheck
npm test
```

## Deployment

This is a stateful, long-lived WebSocket service, not a generic serverless route. Run one replica for the current protocol: each connected editor owns in-memory admitted snapshots, active model work, pending receipts, and bounded conversation context. A reconnect intentionally starts a fresh session.

Build the included container from this directory. It compiles TypeScript, listens on `0.0.0.0`, and honors the standard `PORT` environment variable (with `ASTRA_SESSION_PORT` taking precedence). Because that binding is non-loopback, `SESSION_ACCESS_TOKEN` is required at process startup. Inject `OPENAI_API_KEY` and `SESSION_ACCESS_TOKEN` through the deployment secret manager; never bake them into an image or app bundle. The OpenAI key stays server-side; provision the demo session token privately into the app's Keychain. The service closes open WebSockets during `SIGTERM`/`SIGINT`, aborts active model work, and has a bounded forced-close fallback so deployment shutdown does not wait indefinitely for a client.

```sh
docker build -t astra-session .
docker run --rm -p 8787:8787 \
  -e OPENAI_API_KEY -e SESSION_ACCESS_TOKEN \
  -v astra-illustrations:/app/.local/illustrations \
  -e PORT=8787 astra-session
```

`ASTRA_ILLUSTRATION_DIR` selects the illustration store. Development defaults to the repository's ignored `.local/illustrations`; the container uses an owned `/app/.local/illustrations` directory. Mount a persistent volume there to retain cached images and immutable provenance across restarts; a host bind mount must be writable by the container's `node` user. Storage is capped at 128 MiB and 64 PNG artifacts, with bounded generation receipts/cache keys. Eviction removes the oldest retained artifacts and their receipts. Sessions and in-flight jobs remain in memory and are intentionally discarded on reconnect.

Use an HTTPS/WSS-capable proxy or platform ingress in front of the container. It must pass WebSocket upgrades through to `/session`, expose `GET /health` for liveness, and keep the authenticated `POST /realtime/client-secret` and `GET /illustrations/artifacts/<sha256>.png` routes reachable. Do not deploy more than one replica until session affinity and reconnect ownership are designed explicitly.

## Session wire

The first WebSocket message is the coordination envelope `session.hello`, then the native app sends a complete `phone.snapshot` before any `user.request`. The service emits `session.accepted`, `session.progress`, `session.error`, and `session.explanation` coordination messages. It also emits unmodified portable scene messages `generation.begin`, `generation.batch`, `generation.finish`, and `scene.patch` defined by [the portable scene contract](../framework/contract/README.md).

`user.stop` and `user.undo` carry the incremented native intent epoch. They cancel live model work and pending explanation cues; the service never retags a delayed result with that new epoch or revision. `scene.receipt` is evidence of an installed/rejected batch or patch. `generation.receipt` reports accepted/completed/rejected generation-scope transitions. An explanation attached to a mutation releases only after every scene mutation for its proposal has an installed receipt at the original intent epoch. A distinct `explanation` proposal has zero operations and releases immediately against its admitted scene; this supports read-only questions and explicit clarification when a deictic request has no selection.

Inbound UTF-8 JSON and WebSocket payloads are capped at 256 KiB. The app owns the authoritative accepted scene: its snapshot is a bounded mirror used for admission and model context, and the service keeps no scene database. Before each Astra call, the service compacts repeated scene descriptions into shared context references and supplies up to six terminal conversation outcomes; this history is explanatory context, never current scene authority. Per-message unknown fields are rejected at the coordination boundary. Native `SpatialCore` still performs the final transactional validation, generation ordering, resource caps, and exact hash verification.

The service makes one direct strict function call (`propose_scene`) per text request. It accepts only a completed function-call event, so partial argument deltas cannot mutate a scene. If local normalization rejects a proposal before anything reaches the device, it permits exactly one repair request carrying that validation error. It has no phrase-to-fixture path and no Programmatic Tool Calling path yet. PTC and mid-turn steering stay deferred until the direct scene/receipt loop is observed on-device.

`POST /realtime/client-secret` accepts `{ "sessionId": "..." }` and creates an OpenAI GA ephemeral credential for a direct native `gpt-realtime-2.1` WebSocket. The native conversation adapter sends typed text and local speech through one Realtime session. Realtime calls the app-bound `ask_astra` tool; the app then invokes the scene service and returns its terminal result as `function_call_output` before requesting the final text or audio response. This service still never relays raw audio or owns native scene installation.

## Current limits

Clients advertising `flow.v1` can author generic node-bound flow annotations through the same single `propose_scene` tool. A semantic `flow` operation expands to ordinary geometry, material and node creation; follow-up recipe replacement preserves the annotation node's identity. The normalizer checks source/target bindings against the final candidate hierarchy, forbids endpoints inside flow subtrees, limits scenes to 32 flow instances, and preserves native receipt/Undo authority. Endpoint coordinates belong to the endpoint node; intermediate route points belong to the annotation. Optional `phone.snapshot.nodeLocalBounds` supplies at most 128 finite, ordered host measurements, validated against that exact snapshot's node IDs and copied into the model's admitted context.

`removeNode` is nonrecursive. Its normalization explicitly removes incident observed relationships in the same bounded patch; unrelated relationships remain. The proposal must also explicitly remove every child or dependent flow annotation that would otherwise retain a dangling node reference. Flow schemas, generic flow recipes and existing flow geometry reuse are all gated by the negotiated client capability. The paths are explanatory annotations, not simulated physical measurements.

Clients advertise `illustration.v1` separately from geometry capabilities. With an image provider configured, `session.accepted.illustrationEnabled` is true and the existing single `propose_scene` schema gains a nullable illustration intent. Only an explanation with zero scene operations may request an image. The backend supplements the bounded brief with admitted component semantics; it generates one 1024 × 1024 medium-quality PNG with `gpt-image-2.5-flare`, or refines a retained image through the direct edits API. The ordinary explanation completes immediately while independent `illustration.state` events report generating, ready, failed, cancelled, or stale.

Image work has its own 150-second deadline, at most two provider calls globally and one active job per session. PNG validation permits at most 2048 pixels per dimension and 12 MiB; bytes, checksums, MIME type and immutable generation provenance live in the artifact store rather than scene snapshots. Identical admitted requests reuse cache entries without a provider call. A changed scene ID, document or revision fences late completion; an ordinary conversational epoch advance preserves the image job. `illustration.cancel` explicitly cancels image work, while `illustration.retry` starts a new image-only job from a retained failed/cancelled admission and never repeats scene authoring or mutation. Refinement metadata is limited to four retained images from the current scene.

The direct authoring normalizer supports geometry, material, node, transform/material/geometry/visibility changes. Aliases are bounded opaque text and resolve to stable IDs derived from the immutable user request ID and model aliases. The service computes the same typed binary request hash as `SpatialCore` (Astra Canonical Request v1). A rejected pre-delivery proposal is retained only as a bounded local stderr audit record before its single repair attempt; it is never sent to the scene executor or replayed. Relationship authoring, multi-batch streaming, persistence, reconnect replay, and PTC remain outside this first live path; the Realtime app tool is implemented at the conversation boundary and is not a second authoring normalizer.

Tests inject a model transport. They cover complete-function-call admission, one bounded pre-delivery repair, receipt-gated explanations, stale-revision fencing, and the shared canonical-hash vectors; they do not claim an OpenAI or device integration result.

## Sources

- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [OpenAI async tool calling](https://developers.openai.com/api/docs/guides/async-tool-calling)
- [OpenAI mid-turn steering](https://developers.openai.com/api/docs/guides/steering)
- [OpenAI Realtime and audio](https://developers.openai.com/api/docs/guides/realtime)
- [Portable scene contract](../framework/contract/README.md)
