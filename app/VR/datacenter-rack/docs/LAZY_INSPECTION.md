# Saved models loaded on demand

The starting file is `models/lazy/rack-exterior.blend`: one vertical rack with eighteen server exteriors. Detail lives separately in `models/lazy/parts-library.blend`, indexed by `models/lazy/manifest.json`. The loader never regenerates geometry or reads the detailed library merely because the add-on registers or a scene opens.

Load the session tools after opening the exterior file:

```sh
/path/to/Blender /absolute/path/models/lazy/rack-exterior.blend --python /absolute/path/source/lazy_inspector.py
```

In the 3D View press **N**, then **Rack Lab**. `lazy_inspector.py` registers the existing part inspector alongside its Equipment and Detail panel. It does not install anything machine-wide. The separate question bridge may register afterward; when its `Scene.rack_question` property and `racklab.ask_question` operator exist, the panel exposes its question field and **Ask** button. The loader has no network or natural-language implementation.

## Inspection flow

Select a server exterior, then choose the required detail:

| Control | Saved asset | Content |
|---|---|---|
| Load Inside | `server.mechanical` | Open mechanical server: chassis, carriers, fans, heatsinks and source cables; excludes motherboard, RAM and closed cover |
| Motherboard | `server.motherboard` | Registered board, CAD sockets/connectors/CPU mechanisms and source-listed PCB population |
| Memory | `server.memory` | 32 documented-class analogue RDIMMs at source positions; fitted manufacturer SKU remains unasserted |
| Processor Study | `processor.study` | Separate explanatory processor learning module; not a transistor-layout model |

The first request appends only the named saved collection using `bpy.data.libraries.load(..., link=False)`. Later requests reuse the same cached collection, including across different servers. An inspection scene links the loaded collection directly, so its component objects are selectable. A collection instance alone in the rack would not expose those parts individually.

While inspecting a server, its exterior instance is temporarily hidden and its requested details can be instanced at the same rack position. Requested server assets accumulate in that server's service view: loading the motherboard after mechanical detail adds it to the already opened server. The processor study opens separately. An asset-wide request fits its bounds without arbitrarily selecting a subpart; an explicit part request selects and frames the identified object.

**Back to rack** restores the selected server's original exterior visibility and removes the temporary detail instances from the rack. Its service scene and cached asset remain available for reuse. **Unload selected details** closes that server's inspection scenes, restores the exterior, and releases imported data that is no longer used. **Unload unused cached detail** retains assets referenced by another server/service scene. Only data imported by this add-on is eligible for cleanup; it does not perform a global orphan purge.

The panel reports cached detail asset, object, mesh and vertex counts. These are actual datablock/geometry counts, not an estimate of total RAM or GPU memory.

## Equipment controls

**Add server** uses the existing closed exterior collection and an empty two-OU slot at OU1, 3, …, 35. Choose a specific slot or **First available**. A full rack reports that no slot is free. **Remove selected server** removes that server's rack instances and inspection state; the saved asset libraries remain intact. Add the same slot later to restore its exterior instance.

**Add rack** copies the exterior rack template's object/collection graph using linked mesh data. It assigns a new rack ID, updates server and part IDs, and places the new rack 1.1 m to the right of the rightmost existing rack. It copies the current exterior template inventory, omits temporary loaded detail instances, and loads no detailed library. Adding a server or rack frames the new selection. The default file remains a single rack until this control is used.

Server instances use `part_id` and `server_id` such as `rack01.server01`, `asset_id='server.exterior'`, `rack_id`, and `slot_ou`. Source component IDs remain source identities within the selected server context; they are not fabricated per-instance manufacturing records.

## Structured intent API

Call this on Blender's main thread. A bridge must queue external requests onto that thread.

```python
import lazy_inspector
result = lazy_inspector.handle_intent({
    'action': 'inspect',
    'asset_id': 'server.motherboard',
    'server_id': 'rack01.server03',
    'part_id': 'pcb.U14',
}, context=None)
```

`context` is optional and may be positional or named. Accepted actions:

- `inspect`: one of the four saved detail asset IDs, a real server ID (or selected server), and optional `part_id`.
- `show_rack`: return to the rack and restore the exterior.
- `unload`: unload the specified or selected server's detail and release unused imported assets.

An inspection result contains `status='loaded'`, `asset_id`, `server_id`, `collection`, `cache_hit`, `scene`, `part_status`, `part_id`, `candidates`, `framed` and cached geometry `stats`. `part_status` is `found`, `not_requested`, `not_found`, or `ambiguous`. The loader first matches an exact part ID; a `pcb.X` request may then match recorded `refdes` or `socket_refdes` metadata. It does not infer identity from vague labels. Missing or ambiguous parts retain that result and show the requested asset context rather than claiming an exact match. Errors return `status='error'` and `message`.

Inspection changes `context.window.scene`. A scene-local answer panel should write the answer to the new scene after the call returns. Service scenes record `lazy_selected_server_id` and `lazy_active_asset_id`; returning to the rack preserves the selected server ID for subsequent questions. Generic processor questions still use a supplied/selected server for Back-to-rack context; the question resolver can explicitly default to `rack01.server01`.

## Persistence and editing

A normal Blender save preserves requested cache collections, service scenes, server links and the original exterior visibility. On reopening, registration reindexes those existing collections without appending new detail. Saving an inspection session naturally saves its loaded detail; it does not rewrite the separate saved-model library. The shipped exterior-only file should be kept as the lightweight starting artifact.

Cached collections are shared. Component edits in a service view affect that cached model wherever it is reused during the session. Use Rack Lab's reversible transform controls for inspection and save deliberate authoring changes separately before unloading. Unload is a memory-management operation, not a save operation. The disk library is never overwritten by these controls.

## Verification

`research/lazy-inspector-tests/smoke.py` creates a clearly labeled isolated four-asset fixture, writes it to a library, clears it from memory, then exercises the actual append path. Twenty-eight checks passed: no registration append, only requested geometry loaded, cache sharing across servers, component selection, exterior restoration, server/rack changes with linked meshes and corrected IDs, standalone processor loading, rejection of unsupported actions, and safe removal of unused imported detail.

`persistence.py` adds four save-stage and seven separate-process reopen checks. It verifies that cache and server state survive a real `.blend` round trip, registration appends nothing, the next request is a cache hit, exact part selection still works, exterior visibility restores, and the reopened imported data can be unloaded. Five additional module-reload checks prove repeated registration preserves server/cache state without appending data and retains only one file-load handler. These are 44 isolated assertions in Blender 5.3.0 Alpha. The actual packaged rack's initial/detail mesh counts and visible end-to-end interaction are separate integrating-task acceptance checks.

Actual add-on registration, append/cache actions, equipment changes, cleanup and errors append to `logs/lazy-inspector-actions.jsonl`. Logs describe operations that occurred; they do not claim a live AI model, voice session, physical clearance, or device acceptance.
