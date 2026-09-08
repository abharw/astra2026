# Agent operating contract

## 1. Preflight and launch

Run from the repository root. Complete preflight when the checker exits zero; it checks real binary headers, collection manifest entries, metadata and exports.

```sh
git lfs pull
python3 datacenter-rack/scripts/check_package.py
export BLENDER_BIN='/absolute/path/to/Blender'
python3 datacenter-rack/scripts/launch_rack.py
python3 datacenter-rack/scripts/rack_question.py --state
```

Wait for the launcher's `.runtime/blender-gui.log` to contain `RACK_LAB_READY` before requesting state. `.runtime/bridge.json` is generated locally with a loopback port and token. The CLI reads it privately. Keep that file out of output and version control. The initial state should show `loaded_detail_collections: []`, 80 objects and 21 meshes. Registering the tools does not load detail. Use one launched Rack Lab session per checkout; the runtime bridge configuration points at the most recently launched session.

## 2. Choose a loading route

| Route | When to use it | Entry point |
|---|---|---|
| Question CLI | Interactive agent operation with known equipment vocabulary | `scripts/rack_question.py 'Show the CPU in server 3'` |
| Structured intent CLI | The agent has resolved an explicit part/asset | `scripts/rack_question.py --intent JSON` |
| Blender main-thread API | Plugin/add-on integration or equipment edits | `lazy_inspector.handle_intent(...)` |
| Native sidebar | User-driven selection and inspection | N → Rack Lab |
| Direct library append | Another Blender tool needs raw saved collections without Rack Lab behavior | `bpy.data.libraries.load` using the manifest |
| Other engine | Unity/RealityKit/web/robot runtime integration | Manifest plus exterior GLB/USDZ; detail needs an engine-specific export/loader |

### Question or explicit intent

```sh
python3 datacenter-rack/scripts/rack_question.py 'Show the CPU in server 3'
python3 datacenter-rack/scripts/rack_question.py 'What does U14 do?' --server rack01.server03
python3 datacenter-rack/scripts/rack_question.py --intent '{"action":"inspect","asset_id":"server.motherboard","server_id":"rack01.server03","part_id":"pcb.U14"}'
python3 datacenter-rack/scripts/rack_question.py --intent '{"action":"show_rack"}'
python3 datacenter-rack/scripts/rack_question.py --intent '{"action":"unload","server_id":"rack01.server03"}'
```

The outer response has `request_id` and either `result` or `error`. For questions inspect `result.load_result`; for intent calls inspect `result.result`. A successful inspection returns `status: loaded`. Check `part_status: found` and the returned `part_id` before saying a specific part was selected. `cache_hit` distinguishes reuse from disk load. Inspect the returned state to confirm the resulting scene. Missing/ambiguous metadata is a request for a narrower target, not permission to invent an identity.

Generate a stable `--request-id` for each logical operation. If a request times out, retry with the same ID; the bridge deduplicates pending and completed requests. A first motherboard load measured about 120 seconds, close to the bridge's 180-second wait. Poll state or retry the same ID instead of repeatedly launching Blender or submitting fresh duplicate requests.

### Blender API and equipment changes

Add the absolute `datacenter-rack/source` directory to `sys.path` and call on Blender's main thread after opening the exterior file:

```python
import lazy_inspector
lazy_inspector.register()
r = lazy_inspector.handle_intent({
    'action': 'inspect', 'asset_id': 'server.motherboard',
    'server_id': 'rack01.server03', 'part_id': 'pcb.U14',
})
assert r['status'] == 'loaded' and r['part_status'] == 'found'
```

`lazy_inspector.add_rack()` adds an exterior rack with unique IDs and linked meshes. `add_server(rack_id='rack02', slot_ou=1)` fills a free two-OU slot; use `slot_ou=None` for the first free slot. `remove_server(lazy_inspector.find_server('rack02.server01'))` removes that session instance. A new rack copies the current template inventory, so its existing slots may already be full. The HTTP bridge accepts only inspect/show_rack/unload, question and state; equipment add/remove stays in the native UI or main-thread Python API.

### Direct append

```python
import bpy, json
from pathlib import Path
base = Path('/absolute/path/to/datacenter-rack/models/lazy')
manifest = json.loads((base / 'manifest.json').read_text())
asset = manifest['assets']['server.memory']
with bpy.data.libraries.load(str(base / asset['library']), link=False) as (src, dst):
    assert asset['collection'] in src.collections
    dst.collections = [asset['collection']]
collection = dst.collections[0]
bpy.context.scene.collection.children.link(collection)
```

This low-level route bypasses cache ownership, server selection, view framing and cleanup; the caller owns those steps. Use the Rack Lab API for normal inspection.

## 3. Select the smallest saved asset

| Asset ID | Collection content |
|---|---|
| `server.mechanical` | Open chassis, carriers, fans, heatsinks and cables |
| `server.motherboard` | Board, sockets, connectors and populated reference designators |
| `server.memory` | 32 class-analogue RDIMM modules |
| `processor.study` | Explanatory package and functional architecture |

Read exact collection names and paths from `models/lazy/manifest.json`. Server IDs come from the current scene/manifest, initially `rack01.server01` through `rack01.server18`. Pair a source component ID with its server ID; component IDs alone do not describe a unique physical rack instance. `pcb.U14` identifies the ASPEED BMC; `pcb.U17` is its memory. POWER9 refers to the host processor and loads the separate processor study.

For broader language, use `question_context.get_agent_context(question, server_id=server_id)` and the source metadata (see [QUESTION_CONTEXT.md](QUESTION_CONTEXT.md)) to propose a finite intent. The bundled resolver is deterministic and does not call a model or provide a voice service. Report answer facts together with their source/evidence status. A metadata answer and a successful geometry operation are separate completion conditions.

## 4. Return, preserve edits and unload

`show_rack` restores the exterior view while retaining the cache. `unload` closes the selected server's detail views and frees only imported data no longer referenced by another server. Cached detail is shared; editing it affects every use of that cached collection. Save deliberate changes to a separate session file before unloading. Keep the supplied exterior file as the untouched lightweight starting point.

For a smoke test, load the processor twice for server 3, verify only the processor collection is present and the second result is a cache hit, return to rack, then unload. Complete when state returns to no loaded detail, 80 objects and 21 meshes in a fresh unmodified session. A motherboard run can leave an empty service scene but should release its imported mesh data. Existing live receipts are in `logs/live-*.json`.

## 5. Runtime integration boundary

The GLB has 18 server identities in node extras and shared mesh data. GLB uses Y-up; Blender uses Z-up and meters. USDZ declares its own stage axis/unit metadata. The detailed library is fully supplied in Blender format. Build explicit detail exports, asynchronous asset loading, stable selection IDs and memory disposal for a new engine. Headset rendering, voice, collisions, robot dynamics and per-frame performance remain acceptance work; the Blender demo does not establish them.

For source rebuilds use [REPRODUCING.md](REPRODUCING.md). For measured proof and limitations use [VERIFICATION.md](VERIFICATION.md).
