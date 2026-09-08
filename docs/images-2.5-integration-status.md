# Images 2.5 access and integration status

September 8, 2026, after the repository migration at `ef10dcb`.

The existing backend and native app now integrate `gpt-image-2.5-flare` for generated explanation images and refinement. Real model-driven wire runs and native iPhone/iPad simulator image panels passed. Visual fidelity is only partially accepted, and physical iPhone/iPad presentation remains unverified. No fallback model was used. The [integration receipt](evidence/images-2.5-integration.json) separates these outcomes from the earlier access-only probe below.

## Verified access

[The access receipt](evidence/images-2.5-access.json) records a single `POST https://api.openai.com/v1/images/generations` with `model: "gpt-image-2.5-flare"`, `n: 1`, `size: "1024x1024"`, `quality: "medium"`, and `output_format: "png"`.

| Observation | Result |
| --- | --- |
| HTTP status | 200 |
| Provider request ID | `req_8503a277f93348ea86a2e5a52606464c` |
| Request through completed download and local persistence | 10,898 ms |
| JSON response | 1,015,125 bytes |
| Decoded image | 761,013 bytes; PNG; 1024 × 1024 |
| Reported usage | 43 text input tokens; 439 output tokens; 482 total |
| Output SHA-256 | `bdf16bf37e155afca7cd324a96a97319c4472c59b358f45c5fe10f196c524e3b` |

The actual image and its provenance metadata are retained in ignored `.local/illustration-probe/`, named by the output checksum. The receipt contains the relative file path; the image is not bundled or committed. Visual inspection found all three requested labels, INPUT → PROCESS → OUTPUT, legible and correctly ordered, with two rightward arrows and three blue blocks. This fixed neutral diagram does not test rack-component fidelity, live scene grounding, refinement, or device presentation.

This probe requests one completed image without streaming. It measures completed-response latency, not a partial preview or app display latency. One request does not establish a typical latency distribution or a per-image price.

Earlier read-only probes in the same session returned `404 model_not_found` for `GET /v1/models/gpt-image-2.5-flare` and `GET /v1/models/gpt-image-2.5-sunburst`. A successful `GET /v1/models` listed 131 models including `gpt-6-astra`, but no `gpt-image-2.5` IDs. **Model lookup and listing were not authoritative for Image API access:** the subsequent exact-model generation succeeded. Sunburst generation access remains untested.

## Reproduce the probe

The [probe script](../tools/checks/check-image-access.py) requires an injected `OPENAI_API_KEY`; it neither discovers nor prints secrets. It uses one fixed bounded prompt, a 150-second total deadline, a 12 MiB response limit, and an 8 MiB decoded-image limit. It rejects redirects and stores successful PNG bytes under their checksum. Output contains only the redacted receipt, never image base64 or credentials. A failed request exits nonzero and records the HTTP status, provider error classification and safe message when available; it does not retry or substitute a model.

With the credential already injected:

```sh
python3 tools/checks/check-image-access.py
```

The default receipt is `.local/illustration-probe/access.json`. Use `--report PATH` to select a receipt destination. The recorded run injected only the selected `OPENAI_API_KEY` value from Doppler project `backend`, config `dev`, into the probe's child-process environment. Syntax compilation and missing-credential failure were checked locally, alongside the real successful request.

## Implemented integration

The [existing authoring tool](../backend/src/astra/authoring-tool.ts) retains exactly one completed `propose_scene` call. A negotiated `illustration.v1` capability adds a nullable illustration intent only to an explanation with zero scene operations. The backend validates a brief of at most 2,000 UTF-8 bytes and 1–16 unique observed component IDs, then supplies bounded accepted-scene semantics. Image generation never substitutes for a scene installation receipt.

The [job coordinator](../backend/src/illustrations/jobs.ts) binds every image to the admitted scene ID, document hash, revision, request, intent epoch, and component set. It sends at most one active image job per session and two provider requests globally. Ordinary conversational epoch changes preserve the image job; changed scenes, documents, revisions, explicit cancellation, and disconnection fence obsolete results. Retry repeats only the image job. Refinement uses the retained PNG from the same scene and exact component set; up to four completed image metadata records are available to Astra for follow-ups.

The [direct provider adapter](../backend/src/illustrations/provider.ts) calls `/v1/images/generations` or multipart `/v1/images/edits` with the actual previous image bytes. Each request asks for one 1024 × 1024 medium-quality PNG and has a 150-second deadline. The implementation returns one completed image; it has no streamed preview or invented progress percentage. The conversation explanation can complete while this independent job runs.

The [artifact store](../backend/src/illustrations/store.ts) keeps immutable checksummed PNGs and generation receipts in ignored `.local/illustrations`, with a 128 MiB/64-artifact budget and bounded cache keys. It validates image data and caps individual PNGs at 12 MiB and 2048 pixels per dimension. Metadata records model, checksum, MIME type, dimensions, source revision, component provenance, prompt hash, and refinement source. Fixed quality/output settings currently participate in the cache hash but are not separate artifact-manifest fields. Cache reuse requires the same normalized brief, accepted context, settings, and source artifact; repeated natural-language requests need not produce identical authoring briefs.

The [native loader](../framework/Sources/SpatialApple/Illustrations/IllustrationArtifactLoader.swift) fetches only the canonical artifact route on the configured authenticated backend, rejects redirects, and verifies the checksum, actual byte count, dimensions, and full PNG decode. Downloads have 30-second request/resource deadlines and a 32 MiB disk cache. A wire `ready` event is followed by a local download; the UI becomes ready only after that verification succeeds.

The app's [illustration panel and sheet](../app/SpatialDemo/UI/IllustrationPanel.swift) show actual generating/downloading/retrying states, Stop, Retry, a ready thumbnail, full-image viewing, and dismissal. The inline panel leaves conversation and scene controls available during generation. The full-image sheet temporarily takes over interaction; it does not place a textured plane in AR or replace editable geometry.

## Real provider and wire results

The first integration run used real Astra authoring over the product WebSocket and real Flare generation/editing. Its scene input was a synthetic phone snapshot from the repository rack fixture or an inline teaching-lamp fixture. These are accepted semantic scene inputs, not camera observations or rendered references. All three downloads passed authentication, checksum, dimensions, and byte-count checks; missing and invalid tokens were rejected.

| Scenario | Explanation available | Wire image ready | PNG bytes | Result |
| --- | --- | --- | --- | --- |
| Rack heat-flow illustration | 5.170 s | 19.024 s | 1,191,145 | Real generation; 1024 × 1024 |
| Refine the same image | 2.963 s | 15.689 s | 1,200,817 | Real edit from retained rack PNG; 1024 × 1024 |
| Teaching-lamp energy paths | 2.431 s | 16.665 s | 985,000 | Real non-rack generation; 1024 × 1024 |

Times begin when the wire request is submitted and include Astra authoring plus the image job. They end at the metadata `ready` event, before the separately measured 15–35 ms local downloads; they are not first-preview or native display timings. The edit's retained source is SHA-256 `00eef837d2d5597ec0e513871d46fade2952541ff30a4a8d6ee0fcc97945c5b3`. Full output hashes, source fixture hashes, and local paths are in the integration receipt; generated image bytes remain ignored.

A separate run injected exact `propose_scene` results while using the real image provider. Its repeated rack request reached ready in **13 ms** and returned the identical artifact with **zero additional provider dispatches**. Cancellation and stale-scene cases reached their terminal state with no later ready event during a two-second observation window. Those two cases delayed provider dispatch by one second and cancelled before dispatch, so they do not establish cancellation of an already-running paid provider request or a long-delayed completion. Deterministic provider/session tests cover late completion, transports that ignore abort, retry without scene replay, and scene/receipt races.

## Visual inspection and limits

The initial rack image has readable labels and useful blue intake/red exhaust arrows. It also invents a **2.0 m rack height despite the fixture's 2.210 m value**, highlights an arbitrary visible server position, and presents an exterior whose fidelity to the approved CAD was not established. Its legend calls the exterior source-backed, but the provider received semantics and no assembly render. Component names are grounded in the model context; exact appearance and instance placement are not accepted.

Refinement retained the composition and changed the large exhaust arrows and hot-air label to orange. The legend's exhaust swatch remained red, so requested edit consistency is **partial**. The lamp image clearly separates electrical input, visible light, and heat, using an illustrative incandescent-style bulb. It is not evidence that the observed fixture has that exact bulb, circuit, or exterior.

These observations led to stricter provider instructions against unrequested dimensions, arbitrary instance highlighting, exact-appearance claims without a source render, and inconsistent legend edits. The initial measured runs predate that prompt change; they remain recorded as failures of fidelity rather than being retroactively marked correct. A fresh rack/refinement pair passed the wire path in **16.108 s / 18.200 s**, producing 1,031,789 / 1,054,229-byte PNGs. Inspection found no invented dimensions, explicit schematic qualifications, and correct left-intake/right-exhaust direction. The refined exhaust arrows, hot-air text, and legend were all orange while the earlier layout, labels, and blue intake remained. The tiny rack inset still highlights an arbitrary slot: exact instance position and exterior fidelity remain unverified. This is an improvement observed in one pair, not a guarantee. The first rerun attempt hit `websocket_open_failed` during service restart; the final pair followed a successful readiness check.

## Native app and deterministic checks

Computer control exercised the actual app in an iPhone simulator: a real request generated a ready thumbnail, opening it displayed the full image, and Done returned to the unchanged 20-node rack. Native diagnostics recorded verified local image readiness **23.730 s** after request submission, at revision 0; the PNG was 1,110,219 bytes. A subsequent cold-aisle question completed while the existing image remained available. The image was already backend-ready before that question was admitted, so this interaction does **not** establish native conversation overlap during generation.

The iPad Air 11-inch (M4) simulator also generated from its actual 20-node rack context. Its verified local image was ready in **19.055 s**, with 910,751 PNG bytes. Computer control observed the ready panel with the rack visible behind it and opened a large image showing readable flow labels, blue intake, orange exhaust, and an illustrative qualification. These visual checks used computer-control screenshots; no saved screenshot file is claimed.

The backend's latest check passed 173 tests. Native verification passed 91 Swift Testing cases plus six XCTest cases, with five explicit environment/resource-gated skips. Signed-device and simulator builds passed, and both physical devices received the updated app. Their locked screens prevented physical illustration-panel acceptance. No physical AR frame-rate, hand-pointing, microphone, thermal, or sustained interaction claim follows from the simulator or wire checks.

Focused tests cover artifact corruption and eviction, restart cache recovery, authenticated routing, redirected download rejection, byte limits, cancellation cleanup, retry acknowledgement, stale-download retirement, cross-component refinement rejection, and cache cleanup during concurrent transfers. Actual device image viewing and interaction, broader output fidelity, and the frequency of real-model cache reuse remain open acceptance work.

## Reproduce integration acceptance

The [wire acceptance command](../tools/checks/check-illustrations.mjs) uses the existing saved backend URL/token without printing them. It writes receipts and checked PNGs only beneath `.local/`; all its phone snapshots are explicitly synthetic.

```sh
node tools/checks/check-illustrations.mjs --scenarios rack,refine,lamp \
  --out .local/illustration-acceptance/live

npm --prefix backend run build
doppler run --project backend --config dev --only-secrets OPENAI_API_KEY -- \
  node tools/checks/check-illustrations.mjs --mode injected-authoring \
  --scenarios rack,cache,cancel,stale --out .local/illustration-acceptance/injected
```

The first command requires the running image-enabled backend. The second starts the production server with injected authoring and the real image API; it counts image-provider dispatches. `--observe-ms` bounds the cancellation/stale observation window, and `--help` lists deadlines and scenario boundaries. These calls can generate real images; neither mode treats a mock or a wire receipt as native or visual acceptance.

## Official API sources

Fetched official OpenAI documentation, September 8, 2026:

- [Flare model](https://developers.openai.com/api/docs/models/gpt-image-2.5-flare) and [Sunburst model](https://developers.openai.com/api/docs/models/gpt-image-2.5-sunburst): exact IDs, September 8 snapshots, text/image inputs and raster-image outputs.
- [Image generation guide](https://developers.openai.com/api/docs/guides/image-generation): direct generation and editing endpoints, `data[0].b64_json`, and API choices.
- [Output settings](https://developers.openai.com/api/docs/guides/image-generation#customize-image-output): PNG/JPEG/WebP, dimensions, and quality settings.
- [Image editing](https://developers.openai.com/api/docs/guides/image-generation#edit-images): multipart image references and refinement.
- [Streaming](https://developers.openai.com/api/docs/guides/image-generation#streaming): real `image_generation.partial_image` events; 0–3 requested partials with no guarantee that all requested previews arrive.
