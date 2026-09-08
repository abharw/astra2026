# Asset generation: the complete pipeline

2026-09-08. Proposed design, with research-backed API capabilities and explicit implementation hypotheses. No live generation or latency benchmark has run. Read alongside [architecture.md](../architecture.md), [data formats](data-formats.md), and [storage](storage.md).

## The decision

Build an **editable procedural scene system**. Astra authors spatial source; a trusted compiler/validator turns it into scene data; Swift constructs geometry; RealityKit renders it; the app saves the editable scene when persistence is added.

Use one normalized scene representation and one native execution path. Give Astra two ways to author that representation:

1. **Direct structured calls** for small creations, first useful visuals, and focused edits.
2. **Short JavaScript programs through hosted Programmatic Tool Calling** when loops, arithmetic, and composition make a new assembly easier to express.

The direct path is the implementation baseline. Test the programmatic path with the same geometry capabilities before deciding how often Astra should use it. Neither path has been benchmarked here. This architecture gives model-generated code a useful role without making arbitrary code the device's execution format.

## 1. What “Astra generates an asset” literally means

Suppose the person selects a server and says: “Show a heat sink with twenty-four fins, then spread the fins apart so I can see them.”

The application supplies the selection and a compact scene description. Astra decides that the explanation needs a base, repeated fins, a layout, and explanatory content. It produces geometry parameters and scene operations. It does not need to produce a finished USDZ, a picture, thousands of vertices, SQL, or a frame of video.

A compact authoring fragment might describe:

```json
{
  "geometry": {
    "alias": "fin",
    "kind": "box",
    "size": [0.001, 0.035, 0.08]
  },
  "placement": {
    "kind": "linear_array",
    "aliasPrefix": "fin",
    "geometryAlias": "fin",
    "count": 24,
    "origin": [0, 0, 0],
    "step": [0.006, 0, 0]
  }
}
```

This is a proposed authoring fragment, not a complete transport message. Dimensions are metres. The dimensions and arrangement are invented at request time; generic box and array algorithms are application code. A domain pack may provide real dimensions when fidelity matters.

The backend expands the bounded structural array into twenty-four stable semantic nodes sharing one immutable geometry definition. The device needs one fin mesh and twenty-four placements, plus whatever geometry the base uses. A later “spread them farther apart” changes transforms. It does not require a new mesh, asset download, or database query in the render loop.

This is more expressive than a catalog of prebuilt server-rack scenes. It is also more editable than one opaque generated mesh. The model authors the structure and intent; deterministic code handles repetition, triangulation, normals, native resources, and drawing.

## 2. Three representations with different jobs

| Representation | Optimized for | Owner and lifetime |
| --- | --- | --- |
| Authoring source | Model reasoning, composition, loops and concise edits | Astra outputs JSON arguments or a program; retain actual output as generation provenance |
| Normalized scene IR | Validation, stable IDs, editing, persistence and platform independence | Our application defines the schema; the device owns its accepted state |
| Render artifacts | Fast mesh upload, drawing, picking and animation | Swift builds meshes/resources; RealityKit/GPU hold the active presentation |

IR means intermediate representation: ordinary versioned JSON describing geometry definitions, materials, nodes, relationships, and provenance. It contains concrete bounded data rather than executable expressions. It is the common boundary between model authoring and native execution.

Structural loops from code or authoring conveniences are expanded before the device receives normalized scene nodes. Native geometry recipes still contain parameters such as radius, dimensions, and curve points. Swift expands those into vertices. This keeps node identity explicit without making the model print mesh buffers.

Changing a label should not invalidate a mesh. Changing a node's position should not invalidate its geometry. Changing one fin's shape creates a new immutable geometry definition and changes that node's reference; it does not silently change every other fin sharing the original definition.

## 3. The two authoring paths

### Direct structured tools

The model emits a small JSON recipe/batch or an existing-scene patch through a strict function tool. The function schema describes what can be proposed; runtime validation still checks geometry, references, expansion limits, and state.

Use this for “move this,” “change that part's color,” “show an arrow from this component to that one,” and first coarse structure. A generic bounded array descriptor can already express repetition efficiently. The meaningful comparison is compact procedural JSON versus compact code, not compact code versus an unnecessarily huge vertex dump.

Keep the provider-facing schema smaller than the complete saved-document format. The model sees local aliases, supported geometry, selected/existing node handles, and meaningful parameters. Runtime code attaches request IDs, namespaces, sequence numbers, revisions, epochs, and hashes. Opaque transport fields are not a reasoning task for the model. [Strict function calling](https://developers.openai.com/api/docs/guides/function-calling#strict-mode).

### Programmatic authoring

For a new composed structure, Astra can write JavaScript that constructs the same proposal using loops, functions, arrays, and arithmetic, then calls a proposal tool once per useful batch. It should not call a network tool for every fin or screw.

An illustrative code fragment could compute the placements:

```javascript
const nodes = Array.from({ length: 24 }, (_, i) => ({
  alias: `fin_${i}`,
  geometryAlias: "fin",
  translation: [i * 0.006, 0, 0]
}));
```

OpenAI's hosted Programmatic Tool Calling runs generated JavaScript in isolated V8. The environment has no Node packages, general filesystem, direct network access, or persistent JavaScript state. The application executes returned permitted tool calls, not the program source itself. We cannot assume a custom geometry library can be imported there. The code constructs documented proposal data and calls an enabled tool. [Programmatic Tool Calling](https://developers.openai.com/api/docs/guides/tools-programmatic-tool-calling).

Astra's demonstrated ability to construct editable Blender scenes supports trying code as an authoring interface. It does not establish that Blender, code authoring, or our pipeline meets conversational latency. [Architectural visualization with Astra](https://developers.openai.com/blog/architectural-visualization-with-astra).

### A constraint that changes the implementation

PTC tools cannot be configured as Astra async tools. Keep these adapters distinct:

- A **direct-only async emitter** can remain pending until its batch is installed, rejected, or superseded. Return one final result using its original call ID.
- An **ordinary programmatic proposal tool** can return promptly with a candidate ID and `pending` status. That completes that tool call. The later device receipt is a separate application event, not a second output for the same call ID.

Both adapters call the same internal normalizer, validator, and queue. They do not create two geometry engines. Preserve the hosted program's required continuation items and nested caller metadata. [Async compatibility](https://developers.openai.com/api/docs/guides/async-tool-calling#compatibility).

Successful device receipts update application state immediately. Include a compact trusted receipt summary in the next appropriate ordinary Astra continuation when needed. If the program genuinely needs an installed result, it can make a separate bounded receipt-query tool call; avoid that extra round trip for independent geometry already described completely.

## 4. Admission, normalization, and geometry compilation

These are separate stages:

1. **Admission:** resolve the request against the current selected content, supported capabilities, and an allowed generation scope. The application owns these facts.
2. **Normalization:** resolve aliases, generate stable node IDs, expand bounded structural arrays, normalize materials/transforms, and create immutable geometry definitions. Keep source-to-node mappings for explanation and provenance.
3. **Validation:** check schema, finite values, references, hierarchy, per-batch and total expansion cost. Reject unsupported geometry explicitly. A syntactically valid recipe can still describe an unusable or excessive scene.
4. **Preparation on the device:** derive numeric mesh data, normals, bounds, and simple picking geometry. Reuse a cached mesh when the normalized recipe and compiler settings match.
5. **Native resource creation:** construct or reuse RealityKit resources through the APIs' required isolation. Current mesh APIs have main-actor requirements; asynchronous code does not remove them.
6. **Installation:** recheck epoch/scope/preconditions and reduce operations against the current accepted scene, update its native entities, and emit the execution receipt. Parallel preparation may build immutable resources, but must never overwrite current state with an old whole-scene candidate.
7. **Frame rendering:** RealityKit continues drawing the installed entities using the current camera pose. Rendering is independent of further model calls.

RealityKit supports procedural meshes through `MeshDescriptor`. `LowLevelMesh` is useful for frequent mesh-data changes and custom layouts, but is unnecessary merely because new components arrive incrementally. [MeshDescriptor](https://developer.apple.com/documentation/realitykit/meshdescriptor), [LowLevelMesh](https://developer.apple.com/documentation/realitykit/lowlevelmesh).

The initial compiler is generic geometry code inside the Swift SDK. A complex CAD kernel, arbitrary CSG, or cloud Blender worker can be an additional producer of validated artifacts later. Such a producer should earn its latency and operational cost by enabling useful forms that the fast path cannot create.

## 5. Progressive generation without a round trip per component

The first draft required every batch to wait for the previous installed global revision. That is simple but can put a model/network round trip between every component. Replace it with a restricted generation scope.

1. The backend requests `generation.begin` using the admitted scene ID, intent epoch, and `initialBaseRevision`. Later output retains that immutable admission record even if the current session advances.
2. The device validates that basis and grants a scope for one generation-owned subtree under a permitted parent. A stale begin is rejected.
3. Astra emits complete batches. The backend assigns monotonic `sequence` values and immutable request identities. It may queue several independent batches without awaiting the previous installation receipt.
4. The device prepares within bounded resource limits and commits batches in sequence. It checks scene ID, current epoch, active scope, subtree ownership, references, and the committed sequence cursor.
5. Each commit still increments the global scene revision. Later batches in that same scope depend on its sequence cursor rather than pretending the original global revision remains current.
6. `generation.finish(lastSequence)` completes only after all declared batches have installed. Model-response completion alone is insufficient.

V0 supports one scene-authoring scope at a time. A batch may reference its own earlier nodes and approved anchors; it cannot mutate unrelated content. A competing semantic edit, deletion/replacement of its parent, undo, or new scene-changing intent revokes the scope before mutation. Camera motion and AR tracking updates do not count as semantic document edits.

Normal edits to existing content retain strict `baseRevision` checks. Generation scopes are a narrow ownership rule, not automatic rebasing. Do not silently change an old proposal's revision or epoch to get it accepted.

Reject conflicting reuse of a request identity or sequence. A batch may queue references to earlier sequences, but final dependency validation and installation wait for those sequences to commit; no forward references are allowed. Bound queued bytes, prepared resources, and missing-sequence waiting. Buffer out-of-order batches within those limits and request retransmission of the missing immutable message; after the configured deadline fail the scope. Reconnecting requires a snapshot/cursor reconciliation, not blind replay.

Only execute complete tool-call items. Incomplete JSON arguments or half-written JavaScript may be logged as progress, but must not create scene objects. Small complete batches improve the earliest point at which execution and steering can occur. [Async tool execution](https://developers.openai.com/api/docs/guides/async-tool-calling), [steering boundaries](https://developers.openai.com/api/docs/guides/steering).

## 6. Voice and visual timing

Realtime owns audio conversation; Astra authors spatial content and substantive explanations. A scene change should not need a second Astra call solely to announce a predictable successful result.

Allow Astra to attach a narration cue to a proposal, referring to authored node aliases or operations. After normalization, bind it to actual candidate/node identities, geometry versions, operation/animation identities, and intent epoch. The bridge releases the cue only when its prerequisites hold:

- “I'm creating…” can describe pending work accurately.
- “These are the fins…” requires the relevant content to be installed and current.
- “The fins are now separated…” requires the requested animation to have completed.

Correlate the Realtime response and its audio with the cue and epoch. The device must recheck those requirements before admitting playback and suppress/cancel obsolete queued audio; a bridge-side release check alone cannot guarantee what is still current when speech arrives. Exact response-to-audio gating, playback interruption and truncation are acceptance work for the native transport spike, not an established capability of this app. Failed geometry returns actual error evidence for repair rather than playing a success cue. Speech delivery must not block scene installation.

Speech start provisionally pauses pending installations. A resume, supersede, or failure decision is bound to that speech turn. A scene-changing correction or Stop advances the epoch and fences obsolete work. A non-mutating follow-up can resume compatible work. Give the provisional hold a bounded deadline; lost transcription, disconnect, or unresolved intent ends by cancelling pending installation, never by automatically resuming potentially obsolete geometry.

## 7. What is persisted, and who writes it

**Astra never writes directly to the scene database.** It proposes source data. Application code validates, installs, and saves accepted state.

The first live spike can run in memory. The target Save/Open design is local SQLite containing a complete semantic JSON checkpoint and document metadata, with original binary assets in app files. Save the normalized accepted recipe and scene; retain the model source as provenance where useful. Reopening should not rerun Astra or execute an old source program.

Meshes, native entities, and GPU buffers are derived caches. An imported or externally generated binary whose contents cannot be reconstructed is a retained source artifact. Large USDZ/GLB/texture files live outside relational rows, referenced by identity, hash, media type, and size.

Installation and saving are separate events. After installation, enqueue an immutable checkpoint for background storage; coalesce autosaves. `installed` is not `checkpoint_saved`, and neither proves a display frame. Until the checkpoint commits, a crash can lose the latest unsaved edits. [Detailed storage contract](storage.md).

The backend keeps an acknowledged scene mirror, pending model work, and bounded generation evidence. It does not need a second authoritative scene database. OpenAI conversation state and prompt caching are not our asset persistence layer. A cloud asset library later can add object storage and metadata without putting cloud saves in the interactive drawing path.

## 8. Performance decisions

| Cost | Initial response |
| --- | --- |
| Model emits too much | Compact recipes/short programs, shared geometry, first useful batch before refinement |
| Too many sequential model calls | Batch independent work; generation-scoped ordered commits; gate prewritten cues on receipts |
| Repeated tessellation | Cache by geometry bytes, geometry compiler version, tessellation profile |
| Mesh rebuilding on edits | Transform/material changes reuse existing meshes; geometry edits replace only affected references |
| Main-actor insertion stalls | Bound batch/resource creation, stage work, reuse materials, profile native upload separately |
| Excessive entities/draw work | Separate selectable semantic parts from decoration; instance repeated decoration where appropriate |
| Large network messages | Reuse definitions; send IDs/deltas; keep binary assets out of JSON rather than base64 encoding them |
| Database interference | Encode/write checkpoints away from rendering; coalesce saves; never persist animation frames |
| Unbounded backlog | Per-scope limits, backpressure, cancellation, explicit missing-batch deadlines |

Use separate limits for message bytes, expanded node count, vertices, indices, materials, prepared memory, and queued work. A tiny program or repeat recipe can produce huge output. Geometry complexity and spoken-turn length are not the same budget.

Meaningfully selectable parts retain their own identity. GPU instancing can combine repeated decoration, but do not lose per-part selection to save draw calls. Apple notes that mesh instances belong to one entity, so selection mapping needs deliberate handling. [MeshInstancesComponent](https://developer.apple.com/documentation/realitykit/meshinstancescomponent).

Keep root layout stable: refining an assembly should not continuously recenter/rescale the already anchored scene. Drive animation locally between target states. Do not request new model transforms every frame.

These are architectural expectations. Reducing output and sequential requests is supported latency guidance; the magnitude for Astra and this app remains unmeasured. [OpenAI latency guidance](https://developers.openai.com/api/docs/guides/latency-optimization).

## 9. Why this choice over the alternatives

| Alternative | Why it is not the initial core path |
| --- | --- |
| Model prints raw triangle arrays | Wastes generation on repetitive numeric data and weakens semantic editability |
| New bespoke programming language | Adds grammar/compiler work while ordinary JSON and JavaScript already express the needed structures |
| Model writes arbitrary Swift for the device | Turns content generation into native code compilation/distribution rather than a bounded scene operation |
| Model writes unrestricted JS in our Node service | Requires a real isolation boundary and operational controls; `node:vm` alone is not one |
| Blender/CAD export on every request | Adds worker execution, export, transfer and import before useful content appears; reserve for forms requiring it |
| Third-party text-to-3D for every part | Adds another model/provider and must prove hierarchy, revision control, latency and usefulness |
| Cloud-rendered video | Moves camera-response latency into networking and complicates local selection/AR; unnecessary for initial schematic geometry |
| Database as the live geometry engine | Couples drawing to storage and confuses saved source with runtime resources |

If an application-owned code worker becomes necessary, it must have actual execution isolation and CPU/memory/output limits. Node's own documentation warns that `vm` is not a security mechanism. [Node VM](https://nodejs.org/api/vm.html). This is a boundary for that optional design, not a prerequisite for hosted PTC or direct recipe generation.

## 10. The benchmark that decides the authoring default

Use eight unfamiliar requests spanning small creation, repeated structures, new assembly, component-level edit, existing-asset deconstruction, and interruption. Run each three times on the intended phone/network; distinguish cold/warm geometry caches. Keep renderer capabilities and requested visual detail equivalent.

Compare direct compact recipes against hosted programmatic authoring. First compare valid output quality; then compare one large batch against a few useful progressive batches. Introduce a custom worker only if these cannot express a necessary result.

Record model output/reasoning usage, first complete useful batch, tool rounds, bytes, rejection/repair rate, native preparation/upload/installation time, first actually visible result, frame time, and interruption outcome. Use monotonic clocks within each process and correlate spans; do not subtract unsynchronized device/server wall clocks.

Require unfamiliar follow-ups to edit generated components while preserving unrelated content. Inject a delayed old batch, malformed geometry, lost receipt, missing sequence, failed checkpoint, and a narration cue whose prerequisites never install.

Choose the authoring route by useful results, editability, and measured responsiveness. No claim that PTC, JSON, a particular mesh budget, or a latency target has already won is justified by documentation alone.
