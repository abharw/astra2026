# Astra session service

This is the development-Mac coordinator between the native app and OpenAI. It uses `gpt-6-astra` through the Responses API to author a bounded scene proposal, then sends only exact portable scene envelopes to the device. `gpt-realtime-2.1` is reserved for the native voice session; this service mints its short-lived credential and never relays raw audio.

## Run

Install dependencies once:

```sh
cd services/session
npm install
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

## Session wire

The first WebSocket message is the coordination envelope `session.hello`, then the native app sends a complete `phone.snapshot` before any `user.request`. The service emits `session.accepted`, `session.progress`, `session.error`, and `session.explanation` coordination messages. It also emits unmodified portable scene messages `generation.begin`, `generation.batch`, `generation.finish`, and `scene.patch` defined by `../../contracts/README.md`.

`user.stop` and `user.undo` carry the incremented native intent epoch. They cancel live model work and pending explanation cues; the service never retags a delayed result with that new epoch or revision. `scene.receipt` is evidence of an installed/rejected batch or patch. `generation.receipt` reports accepted/completed/rejected generation-scope transitions. An explanation attached to a mutation releases only after every scene mutation for its proposal has an installed receipt at the original intent epoch. A distinct `explanation` proposal has zero operations and releases immediately against its admitted scene; this supports read-only questions and explicit clarification when a deictic request has no selection.

Inbound UTF-8 JSON and WebSocket payloads are capped at 256 KiB. The app owns the authoritative accepted scene: its snapshot is a bounded mirror used for admission and model context, and the service keeps no scene database. Per-message unknown fields are rejected at the coordination boundary. Native `SpatialCore` still performs the final transactional validation, generation ordering, resource caps, and exact hash verification.

The service makes one direct strict function call (`propose_scene`) per text request. It accepts only a completed function-call event, so partial argument deltas cannot mutate a scene. If local normalization rejects a proposal before anything reaches the device, it permits exactly one repair request carrying that validation error. It has no phrase-to-fixture path and no Programmatic Tool Calling path yet. PTC and mid-turn steering stay deferred until the direct scene/receipt loop is observed on-device.

`POST /realtime/client-secret` accepts `{ "sessionId": "..." }` and creates an OpenAI GA ephemeral credential for a direct native `gpt-realtime-2.1` WebSocket. The current native voice adapter forwards final transcripts as `user.request`; Realtime does not author scene mutations and should not claim an installation. A later `session.explanation` is the receipt-gated content the native voice layer may play.

## Current limits

The direct authoring normalizer supports geometry, material, node, transform/material/geometry/visibility changes. Aliases are bounded opaque text and resolve to stable IDs derived from the immutable user request ID and model aliases. The service computes the same typed binary request hash as `SpatialCore` (Astra Canonical Request v1). A rejected pre-delivery proposal is retained only as a bounded local stderr audit record before its single repair attempt; it is never sent to the scene executor or replayed. Relationship authoring, multi-batch streaming, persistence, reconnect replay, PTC, and voice-to-service tool calls are intentionally outside this first live path.

Tests inject a model transport. They cover complete-function-call admission, one bounded pre-delivery repair, receipt-gated explanations, stale-revision fencing, and the shared canonical-hash vectors; they do not claim an OpenAI or device integration result.

## Sources

- [OpenAI function calling](https://developers.openai.com/api/docs/guides/function-calling)
- [OpenAI streaming](https://developers.openai.com/api/docs/guides/streaming-responses)
- [OpenAI async tool calling](https://developers.openai.com/api/docs/guides/async-tool-calling)
- [OpenAI mid-turn steering](https://developers.openai.com/api/docs/guides/steering)
- [OpenAI Realtime and audio](https://developers.openai.com/api/docs/guides/realtime)
- [Portable scene contract](../../contracts/README.md)
