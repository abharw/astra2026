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

The default endpoints are `GET http://127.0.0.1:8787/health` and `ws://127.0.0.1:8787/session`. `ASTRA_SESSION_HOST` and `ASTRA_SESSION_PORT` configure the listener. A non-loopback host requires `SESSION_ACCESS_TOKEN`; native supplies it only in `session.hello.authToken` and the realtime credential HTTP Authorization header. The health response intentionally reports only whether an OpenAI credential exists.

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
  -e PORT=8787 astra-session
```

Use an HTTPS/WSS-capable proxy or platform ingress in front of the container. It must pass WebSocket upgrades through to `/session`, expose `GET /health` for liveness, and keep the authenticated `POST /realtime/client-secret` route reachable. Do not deploy more than one replica until session affinity and reconnect ownership are designed explicitly.

## Session wire

The first WebSocket message is the coordination envelope `session.hello`, then the native app sends a complete `phone.snapshot` before any `user.request`. The service emits `session.accepted`, `session.progress`, `session.error`, and `session.explanation` coordination messages. It also emits unmodified portable scene messages `generation.begin`, `generation.batch`, `generation.finish`, and `scene.patch` defined by [the portable scene contract](../framework/contract/README.md).

`user.stop` and `user.undo` carry the incremented native intent epoch. They cancel live model work and pending explanation cues; the service never retags a delayed result with that new epoch or revision. `scene.receipt` is evidence of an installed/rejected batch or patch. `generation.receipt` reports accepted/completed/rejected generation-scope transitions. An explanation attached to a mutation releases only after every scene mutation for its proposal has an installed receipt at the original intent epoch. A distinct `explanation` proposal has zero operations and releases immediately against its admitted scene; this supports read-only questions and explicit clarification when a deictic request has no selection.

Inbound UTF-8 JSON and WebSocket payloads are capped at 256 KiB. The app owns the authoritative accepted scene: its snapshot is a bounded mirror used for admission and model context, and the service keeps no scene database. Before each Astra call, the service compacts repeated scene descriptions into shared context references and supplies up to six terminal conversation outcomes; this history is explanatory context, never current scene authority. Per-message unknown fields are rejected at the coordination boundary. Native `SpatialCore` still performs the final transactional validation, generation ordering, resource caps, and exact hash verification.

The service makes one direct strict function call (`propose_scene`) per text request. It accepts only a completed function-call event, so partial argument deltas cannot mutate a scene. If local normalization rejects a proposal before anything reaches the device, it permits exactly one repair request carrying that validation error. It has no phrase-to-fixture path and no Programmatic Tool Calling path yet. PTC and mid-turn steering stay deferred until the direct scene/receipt loop is observed on-device.

`POST /realtime/client-secret` accepts `{ "sessionId": "..." }` and creates an OpenAI GA ephemeral credential for a direct native `gpt-realtime-2.1` WebSocket. The native conversation adapter sends typed text and local speech through one Realtime session. Realtime calls the app-bound `ask_astra` tool; the app then invokes the scene service and returns its terminal result as `function_call_output` before requesting the final text or audio response. This service still never relays raw audio or owns native scene installation.

## Current limits

The direct authoring normalizer supports geometry, material, node, transform/material/geometry/visibility changes. Aliases are bounded opaque text and resolve to stable IDs derived from the immutable user request ID and model aliases. The service computes the same typed binary request hash as `SpatialCore` (Astra Canonical Request v1). A rejected pre-delivery proposal is retained only as a bounded local stderr audit record before its single repair attempt; it is never sent to the scene executor or replayed. Relationship authoring, multi-batch streaming, persistence, reconnect replay, and PTC remain outside this first live path; the Realtime app tool is implemented at the conversation boundary and is not a second authoring normalizer.

Tests inject a model transport. They cover complete-function-call admission, one bounded pre-delivery repair, receipt-gated explanations, stale-revision fencing, and the shared canonical-hash vectors; they do not claim an OpenAI or device integration result.

## Sources

- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [OpenAI async tool calling](https://developers.openai.com/api/docs/guides/async-tool-calling)
- [OpenAI mid-turn steering](https://developers.openai.com/api/docs/guides/steering)
- [OpenAI Realtime and audio](https://developers.openai.com/api/docs/guides/realtime)
- [Portable scene contract](../framework/contract/README.md)
