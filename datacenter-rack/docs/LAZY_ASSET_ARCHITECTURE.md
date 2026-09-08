# Exterior first, saved detail on demand

The default view is **one vertical rack filled with server exteriors**. It does not load the 6,663 motherboard components, the detailed drive assemblies, the individual memory contacts or the processor study.

The detailed models were built in advance and saved in a separate library. A question identifies the requested equipment or component, retrieves its metadata and loads the corresponding saved asset. No modeling or model generation is performed when a question arrives.

## Saved resources

| Resource | When it is used |
|---|---|
| `models/lazy/rack-exterior.blend` | Default stack, frame, power-supply exteriors, visible cables and reusable server shells |
| `models/lazy/exterior-library.blend` | Add another server exterior using the same saved geometry |
| `models/lazy/parts-library.blend` | Append only the requested detail collection |
| `models/lazy/manifest.json` | Asset IDs, library/collection names, rack slots, bounds, coordinate contract and load policy |
| `models/lazy/part-knowledge.json` | Source metadata can be retrieved without opening any geometry |
| `models/datacenter-rack-v002.blend` | Complete detailed authoring master, kept separately from the default view |

The detail collections are `server.mechanical`, `server.motherboard`, `server.memory` and `processor.study`. More than one question may refer to the same collection; the loader reuses the cached collection rather than appending a second copy. Unused imported geometry can be released explicitly.

## Question flow

1. Identify the rack/server and requested component from the question and current selection.
2. Retrieve the component identity, source references and uncertainties from saved metadata.
3. Produce a finite inspect intent, for example:

```json
{"action":"inspect","asset_id":"server.motherboard","server_id":"rack01.server03","part_id":"pcb.U14"}
```

4. Load that saved collection only if it is not already cached.
5. Open an inspection view and frame/select the requested part.
6. Present the explanation with its source boundaries.

The bundled fallback resolver handles known component terms, reference designators and part numbers. It is deterministic evidence retrieval, not a claim of an LLM API call. A Codex/Astra agent can interpret a broader question using the documented context and send the same inspect intent. Unsupported or ambiguous requests return that status instead of inventing geometry or live readings.

The local bridge executes model changes on Blender's main thread. It binds to loopback, requires a local session token and accepts only finite JSON actions; it does not expose arbitrary code execution. The token stays in the ignored `.runtime` directory.

## Interact with the model

Run `python3 scripts/launch_rack.py`, or open `scripts/Open Rack Lab.command` on macOS. `BLENDER_BIN` can select the Blender executable. The launch path opens the exterior file and registers controls; registration does not append the detail library.

The Rack Lab sidebar offers question entry, saved-detail controls, Back to rack, cache unloading, and add/remove equipment. Questions such as “show the CPU in server 3” or “what does U14 do?” resolve to saved assets. The initial rack uses the explicit IDs `rack01.server01` through `rack01.server18`.

For an agent or integration process:

```sh
python3 scripts/rack_question.py --state
python3 scripts/rack_question.py 'Show the CPU in server 3'
python3 scripts/rack_question.py 'What does U14 do?' --server rack01.server03
python3 scripts/rack_question.py 'Show the rack'
```

The command reads the local session token without printing it. Its response reports the source answer, actual load result, cache state and scene/object counts.

## VR integration boundary

The asset IDs, coordinate system, semantic intents and slot layout are independent of Blender. A VR runtime can implement the same policy with downloadable model chunks, cache them by asset ID, and keep each equipment instance's identity and transform separately.

The Blender control flow is an inspectable authoring demonstration. It does not prove headset frame rate, controller interaction, voice transcription, physics or robot-contact accuracy. The exterior is a declared distance approximation derived from the CAD; the detailed source model remains available for closer inspection. Per-component streaming below the current collection boundaries can be added without regenerating the source assets.
