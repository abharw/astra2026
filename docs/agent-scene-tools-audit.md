# Model-facing scene and asset audit

2026-09-08. This audit covers the actual Responses authoring adapter, Realtime handoff, scene normalizer, native imported-part projection, public contracts and local evidence. The changes below are implemented and locally tested. Provider cache hits, model quality and latency after these changes require live acceptance; byte reductions are not token or frame-rate measurements.

## Decision

Keep **binary rendering assets separate from the semantic scene Astra edits**. A Blender export should become an optimized, hierarchy-preserving native package plus a small semantic manifest. It should not become a giant JSON mesh dump in the conversation. Astra should identify the right assembly and propose a short operation; deterministic code should handle IDs, offsets, tessellation, hashing, loading, resource sharing and installation.

The current system already has the right separation, but the original model interface was unnecessarily verbose and weak at follow-up scope. This change improves that interface without changing the native wire contract or adding a new rendering service, database, execution sandbox or asset-specific tool.

## What currently happens to the Blender asset

1. The host approves an `ImportedAssetDescriptor` with the pinned binary digest, URL, measured budget and exact authored part bindings.
2. RealityKit loads the USDZ hierarchy. The native catalog extracts the approved parts and retains their meshes and authored materials.
3. The scene renderer creates normal semantic nodes around those parts. Each node has an ordinary stable `nodeId`, `parentId`, local TRS, name/role/description and provenance. A geometry definition refers to `importedAsset(assetID, partID)`.
4. The device sends its accepted semantic document to the service. The binary meshes never enter the model prompt. The service now builds a smaller authoring view of that document.
5. Astra emits one bounded `propose_scene`. Normalization resolves aliases and derived values. Native validation and resource preparation precede an atomic semantic/native installation. Its receipt determines whether the conversation may report a completed change.

The source rack currently exposes **20 semantic nodes and 19 geometry definitions: an assembly root, a frame remainder and 18 joined server exteriors**. That is a useful assembly interface, but it is not a complete component-level representation of the Blender authoring source. A joined exterior does not magically contain addressable processors, fan blades or boards. The separate source detail libraries need their own verified export and host bindings before they can be revealed as actual imported detail. Existing rendering fidelity and semantic granularity are separate questions. See [native fixture](../framework/contract/fixtures/accepted/imported_rack_document.json) and [intake review](imported-rack-review.md).

## Implemented model context

`astra/scene-context.ts` creates a versioned **model view**, not a replacement saved document. It preserves all nodes, all parent edges, exact current transforms, visibility, names, roles, descriptions, provenance, recipes, materials and relationships. It does not sort away hierarchy, drop unselected siblings, round imported quaternions or truncate the tail of a scene.

Repeated long descriptions and provenance records move into shared dictionaries. Repeated imported `assetID`s also move into a dictionary. Nodes and geometry keep their exact existing IDs. Only application-computed geometry `contentHash` fields are omitted: the model cannot author or verify those hashes, and the original accepted document retains them.

For example, repeated parts may refer to `descriptionRef: "description_1"` and `provenanceRef: "provenance_1"`. Their full values appear once under `acceptedScene.shared`. An imported recipe can use `assetRef: "asset_1"` in this view while retaining its exact `partID`. These references are contextual lookups; they are not new aliases the model should emit. The tool continues to reuse existing geometry by its observed `geometryId`.

The independent round-trip tests expand those references and deep-compare every authoring field with the original document after excluding `contentHash`. They cover the actual native imported rack, the earlier 179-node procedural scene and an unrelated optical assembly. The same production code handles all three; there is no rack-name branch or fixed domain ladder.

This view intentionally remains a full preload for the current scene. A mandatory inspect call before a 20-part edit would add another sequential request. When actual loaded detail grows into thousands of parts, introduce bounded hierarchy queries and a compact assembly index rather than silently slicing the first N nodes. That is a proposed next step, not current behavior. [OpenAI request-latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization#make-fewer-requests).

## Implemented authoring improvements

| Change | Concrete behavior |
| --- | --- |
| Parent-space `translate` | Astra supplies an observed node ID and offset. Code adds the offset to that node's current local position and preserves rotation and scale exactly. Moving a parent carries its children intact. |
| Sequential normalization | Multiple translates, or `setTransform` followed by translate, use the earlier operation's result within the same proposal. The emitted wire operation remains absolute `set.transform`. |
| Explicit scope restriction | Translate accepts existing observed nodes only. Newly created nodes already require an initial transform; a new alias cannot masquerade as an observed part. |
| Automatic provenance | The model no longer repeats node provenance that the normalizer would overwrite. New nodes are always stamped `generated` and `illustrative` by code. Legacy inputs remain accepted but cannot promote themselves to reference-backed truth. |
| Numeric schema constraints | Dimensions, coordinates, tessellation counts and material factors now express native ranges. Tool descriptions explain parent coordinates, metres, quaternion order and alpha requirements. Cross-field validity still needs semantic validation. |
| Exactly one tool | Required tool choice plus `parallel_tool_calls: false` enforces the intended single authoring call. The session still rejects multiple completed proposals defensively. |
| Honest capabilities | Instructions no longer advertise a removal operation absent from the schema. Imported material overrides and invented asset references remain unavailable. |

The translate helper is an **authoring convenience**, not a relative operation that gets replayed indefinitely. It resolves once against the immutable admitted snapshot, produces an absolute target transform and follows the existing request ID, hash, revision and epoch rules. A stale result cannot be retagged onto a newer scene.

OpenAI's tool design guidance recommends clear parameter contracts and having code supply values it already knows. Its strict-function guidance supports one-call enforcement and structural constraints; strict JSON alone does not establish valid target IDs, geometry budgets, factual provenance or native installation. [Function design](https://developers.openai.com/api/docs/guides/function-calling#best-practices-for-defining-functions), [parallel calls](https://developers.openai.com/api/docs/guides/function-calling#parallel-function-calling), [supported schema constraints](https://developers.openai.com/api/docs/guides/structured-outputs#supported-properties).

## Hierarchy and follow-up intent

The prompt now tells Astra to choose the **coarsest sufficient assembly level**. A request to move several assemblies should move those parent nodes, preserving their children. A follow-up explanation should keep the prior scope and reveal or construct only the detail necessary to teach the requested concept. These are domain-independent instructions based on the supplied hierarchy, names and roles; there is no scripted rack → server → processor sequence.

Previously, the Realtime conversation could remember earlier turns but the Responses author received only the newest delegated text and a snapshot. Scene geometry cannot by itself explain what the user had been discussing. The service now includes up to **six whole terminal turns, bounded to 12 KiB UTF-8**, in `recentTurns`:

```json
{
  "userRequest": "Move this assembly forward",
  "selectionNodeIds": ["optics.mount"],
  "result": {
    "status": "installed",
    "explanation": "The assembly is moved forward for inspection.",
    "affectedNodeIds": ["optics.mount"]
  }
}
```

Read-only answers are recorded as `answered`. Mutations are recorded as `installed` only after all matching native installation receipts. Explicit rejection or failure before any proposal delivery may be recorded as `failed`; cancelled, timed-out or unconfirmed work is omitted. A new scene or connection clears history. Epoch changes for normal turns and Undo retain the historical conversation, while the current snapshot remains authoritative. Removed selected/affected IDs are pruned when supplying history. Oversized turns are omitted whole rather than clipped mid-meaning.

Explicit current selection has priority over earlier focus. With no selection, the model may use the recent discussion only when the current hierarchy makes the target unambiguous; otherwise it asks a natural clarification. This improves context but does not guarantee perfect model scope selection. Real multi-turn evaluation is still necessary.

The current portable node contract contains **current pose**, not a separate immutable rest pose, bounding box or structured loaded/available-detail index. Some imported coordinate and absence information is present as host-authored semantic descriptions. Do not claim these stronger fields are already universal. A future generic manifest should provide part hierarchy, current/rest transforms, bounds, source status and registered detail availability without tying runtime behavior to one asset family.

## Caching and observable stages

The Responses adapter retains `gpt-6-astra`, low reasoning effort and the existing output budget. It places stable instructions into a developer `input_text` block with an explicit cache breakpoint and keeps current request, scene and history after that breakpoint. `prompt_cache_options` uses explicit mode with the documented 30-minute minimum lifetime. This is the current documented GPT-5.6-and-later interface; top-level instructions cannot contain an explicit breakpoint. It does not guarantee a cache hit. [Prompt caching](https://developers.openai.com/api/docs/guides/prompt-caching#choose-a-caching-mode).

The client now distinguishes the first raw provider event, first function-argument delta, complete function arguments and completed response. It records numeric input/output, cached/write and reasoning token counts when the provider returns them. The diagnostics filter permits only specifically named nonnegative integer metrics; prompt text, argument content, transcripts and credentials remain excluded. Missing usage remains absent rather than being reported as zero.

`session.progress` now reports `generating` on the first actual function-argument delta and `processing` after response completion before normalization. Existing `thinking`, repair and installation stages remain. Streamed argument fragments are never executed as scene mutations. These stages describe real work and allow the app to animate truthful activity rather than invent a timed sequence.

## Local measurements

The repeatable script is `cd backend && npm run check:context`. [Measured evidence](evidence/model-context-optimization.json) pins the fixture and implementation hashes.

| Measurement | Before | After | Reduction |
| --- | ---: | ---: | ---: |
| Actual imported rack context, 20 nodes / 19 definitions | 20,003 bytes | 11,926 bytes | 40.38% |
| Procedural rack context, 179 nodes / 32 definitions | 81,125 bytes | 66,691 bytes | 17.79% |
| Output operations to translate all 18 imported units by one parent-space offset | 4,106 bytes | 1,225 bytes | 70.17% |

These compare compact UTF-8 JSON. They exclude fixed tool/prompt overhead and bounded conversation history. They do not establish token reductions, cache hit rate, milliseconds, model correctness or mobile FPS. OpenAI's latency guidance identifies generated output as a common dominant cost, which motivates the smaller translate operation, but a byte ratio must not be presented as a measured speedup. [Output latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization#generate-fewer-tokens).

The backend typecheck and **41 tests** pass, including exact-pose translation, stale admission, source-fact round trips, generic optical hierarchy, receipt-bound history, cancellation, new-scene isolation, UTF-8 bounds and content-free metrics. Provider acceptance of the updated schema/cache request and repeated real scene tasks is the next validation boundary.

## Remaining optimization priorities

1. **Semantic detail export and inspection.** Preserve source hierarchy, instance identity and meaningful assemblies; merge insignificant decoration within the owning assembly. Expose registered detail availability separately from currently loaded content. Add a generic bounded inspection/load tool only when those assets actually exist and the native loader can return truthful results. Do not promise arbitrary depth merely because a `.blend` file contains thousands of objects.
2. **Generic compact repetition.** The current schema still creates repeated nodes individually. A bounded structural repetition operation could reduce output for fins, bolts, pins or optical elements while retaining separate semantic identities. Some older design prose described this as implemented; it is not. Benchmark the helper against direct nodes before adding program execution.
3. **Cross-field proposal validation.** Schema ranges now reject many invalid values early, but unit quaternion magnitude, arrow head length versus shaft length, zero-length tube segments, imported material restrictions and whole-scene budgets remain semantic checks. Native rejection is safe, but there is no general post-native-rejection model repair loop. An additional repair round must remain bounded and tied to the current admitted scene.
4. **Measure the actual conversation chain.** The current unified path includes Realtime tool selection, Astra authoring, native receipt and Realtime final response. Those serial stages improve conversational continuity and truthful narration but each has cost. Measure tool-ready, authoring-complete, installed and final text/audio onset separately before replacing orchestration. The current Realtime function-result flow uses the original `call_id` and a subsequent response request. [Realtime function calling](https://developers.openai.com/api/docs/guides/realtime-conversations#function-calling).
5. **Real quality/latency comparison.** Run the same selected assembly translation, plural sibling move, follow-up explanation, generated annotation and missing-detail question with and without compact context. Evaluate correct scope, unchanged children, exact rotation/scale preservation, native acceptance, output tokens, cache reads, time to installed change and truthful final narration. A smaller payload that makes the model choose the wrong part has lost the comparison.

Neither a new SDK nor cloud mesh rendering fixes missing semantic structure. The next major improvement is a verified, generic asset/part manifest and a model interface that exposes precisely the relevant hierarchy and available operations.
