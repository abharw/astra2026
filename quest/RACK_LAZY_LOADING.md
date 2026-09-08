# Authored rack and on-demand parts

The Quest environment adds the source-derived Open Rack V2 with 18 Barreleye G2 server instances. Its original height is 2.21 m. The rack starts in front of the wearer at a floor-level world anchor; an existing saved rack waits for anchor localization instead of spawning a duplicate. Ordinary camera reconstruction remains available alongside it. The black instruction canvas has been removed at the wearer's request. A small microphone status badge below the center of view shows Off, connecting, speaking, microphone permission, offline or error. The entire badge is invisible while listening. The badge is non-interactive and does not block pointer selection.

## Using the rack

Hold **B on the right controller** for about half a second to enable or stop voice. When the badge disappears after connecting, the microphone is listening and you can ask your question. Away from a rack selection, a short B press also toggles voice. A voice connection that does not become ready within 25 seconds shows an error and can be retried by holding B.

- Trigger selects the rack frame, a server or a loaded component.
- **Tap B on the rack, a server, or one of its loaded components** stages one complete server. Its closed chassis first slides fully beyond the rack front, pauses, moves into view, and pauses again. Only then do its eight internal groups lift into two columns above the open chassis. The chassis remains below them. If the frame is selected, the app chooses a server near viewing height.
- Loading overlaps the closed-chassis motion. The sequence works offline and waits for native mesh readiness before opening. Previously loaded groups in other servers remain hidden and those servers stay closed.
- The complete layout remains available for inspection. B does not automatically pull the first component forward or begin a voice tour. Select or ask about a component to focus or explain it; ordinary voice walkthroughs remain available.
- **Right grip** grabs and drags the selected whole assembly; release leaves it there. This applies to the entire rack, even when a component was selected. Part-specific placement remains available through voice controls.
- **Left-stick click** toggles the whole assembly between its original/home scale and compact inspection scale without returning it home. While held, the size change follows the grab; after release, the rack keeps its base at the current placement. For generated models, original means the saved original fitted scale.
- **Right-stick click** restores the original home pose and scale. **A** reassembles/explodes. **Y** cancels a running demo, walkthrough or load.
- **Y** on a selected rack server loads its nine internal teaching groups. **Y** during a pending load or demo cancels it.
- Voice can load a single group immediately: “Show the processors in server 3”, “Load the memory in server 8”, or “Show the fans in this server”.
- “Unload the memory in server 8” releases that group's scene instance; resources are freed when no other instance uses them.
- “Load all the parts in this server and float them” loads its nine groups and then explodes them into a separated 3-by-3 layout. **A** also toggles explosion/reassembly. Each group supports voice focus, move, rotation and scale. A full-server explanation loads the groups before walking through them.
- “Explain this part” focuses it and explains its source information. “Return the object”, or right-stick click, restores the rack and closes its interior views. Closing a view retains its already loaded detail; unloading removes the detail.
- Existing grip, rotation, scale, whole-object pull/return and generated-object controls remain. Part-specific voice movement affects that component and its descendants. Left grip + left-stick click still retries anchor restoration; an unmodified left-stick click now changes size.

Available groups are **storage, fans, processors, heatsinks, network, power, chassis, motherboard and memory**. These are the existing authored teaching groups. Exact installed RDIMM SKU/capacity, live telemetry, detailed circuits and finer source CAD are not established by this package.

## Harness interface from startup

`scene.update.available_asset_details` publishes the rack object ID, server IDs, all nine group descriptions, current availability, loaded component IDs and evidence limits. This metadata is available before any detail mesh has been requested. The voice scene context includes it as `availableAssetDetails`.

`load_asset_detail({server, part})` and `unload_asset_detail({server, part})` accept catalog server IDs such as `rack01.server03`. `part` is a group ID (`processors`, `memory`, `fanwall`, etc.) or `all`; an empty server resolves to the selected server. The backend checks the catalog and sends a request bound to the current selection version. It waits for native `command.result` before reporting success. A changed selection, deleted rack, cancelled load or missing catalog entry returns a truthful failure.

The harness can ask for one group directly. It does not need to open a complete server first. Loaded semantic IDs use `rack01.server03.detail.processors`, preserving the real server instance association. The existing model-refinement tools preserve the authored rack and direct the harness to the approved loader; ordinary generated models retain their existing refinement path.

The B sequence ends with the server selected and its full inspection layout stationary. It cancels an earlier voice tour but does not start a new one. Explicit voice walkthroughs retain device-acknowledged steps, and `walkthrough.started` / `walkthrough.stopped` keep cancellation state in sync. New selection, grabbing, resizing, Return or cancellation interrupts stale demo work. The active server scope is preserved through lazy model replacement and limits which loaded internals are shown.

## Implementation

| File | Responsibility |
| --- | --- |
| `Tools/export_rack.py` | Offline Blender import of pinned USDZ; indexed meshes, split normals, source materials, instance mappings and package checksums |
| `SourceAssets/AravRack/` | Original exterior/teaching packages, source catalogs and licenses from Arav `ef10dcb` |
| `Assets/StreamingAssets/Rack/` | Exterior package, nine separately compressed detail packages, host catalog and licenses |
| `Assets/SpatialAssembly/Runtime/RackResources.cs` | Verified async reads, bounded background decoding, main-thread mesh creation, shared resource ownership and per-instance highlighting |
| `Assets/SpatialAssembly/Runtime/RackWorld.cs` | Default placement, initial capability catalog, source evidence, detail patches and selection/cancellation checks |
| `Assets/SpatialAssembly/Runtime/AssemblyModel.cs` | Imported geometry alongside ordinary generated primitives; semantic selection and descendant transforms |
| `Assets/SpatialAssembly/Editor/RackRenderProof.cs` | Offline native Unity rendering of the exterior and requested detail views; no headset/bridge access |

Gzip payloads use the `.rackbin` extension so Unity Android preserves their original bytes and catalog filenames; `.gz` files are automatically expanded during APK packaging.

The compiler reflects Blender X and maps Z-up into Unity Y-up, then reverses triangle winding to retain outward normals. Meshes are normalized by 2.21 for the existing assembly renderer; the world root restores that scale. Shared server geometry remains instanced. Source materials retain base color, metalness and roughness; neutral reflection lighting is an approximation of the environment, not a captured room reflection.

Compressed runtime geometry totals about 19.9 MB; only the exterior is initially decoded. The source exterior contains 791,123 unique triangles and about 2.99 million after the 18 server occurrences are expanded. The internal teaching package contains 381,897 triangles across its nine groups. These are content counts, not a measured Quest frame-rate result. Selectable components use bounded box colliders; four thin frame hit volumes leave the front opening clear for server selection.

The saved object contains source identity, loaded semantic parts, home/current pose and interior visibility. Meta anchor localization still gates restoration. Per-part inspection transforms remain session state, consistent with the pre-existing implementation. Delete records the default rack's removal so it does not reappear on every launch.

## Build and evidence

Use the existing [Quest build setup](README.md). To reproduce the asset conversion with the pinned source packages:

```sh
/Applications/Blender.app/Contents/MacOS/Blender -b --python quest/Tools/export_rack.py
```

Native Unity preview rendering showed the exterior, a direct processor-only view, and a complete server interior. That work caught and corrected source handedness, early Unity-object initialization and resource-release issues. It is local import/render evidence. No headset camera inspection, voice request, scan or remote interaction test was performed for this revision; the wearer retains headset acceptance.

The pre-addition source is preserved remotely at **`quest-before-rack`**, commit `fe9be8a`. It includes the earlier Quest features and architecture handoff, without this rack addition or panel removal. Keep the previous paired APK separately for an authorized binary rollback. Never commit pairing tokens or API keys.

Delivery: the final Android APK built successfully, its ten catalog packages were verified inside the APK, installation returned Success, the matching backend was restarted and the app launch command succeeded. Saved models were retained. Headset acceptance remains with the wearer.

The combined demo/indicator/size-control APK `spatial-assembly-quest-rack-demo.apk` is now installed. At the wearer's request, only the saved laptop model was removed; the rack and VR controller were preserved. The app was launched after headset wake. The subsequent quiet-mic update also installed successfully: the badge is hidden while listening and reads Off when voice is disabled. Controller/voice acceptance remains with the wearer; no headset interaction tests were run for these additions.

The chassis-first revision replaces the fixed 40 cm extraction with a distance derived from the rack front and selected server back edge, plus 12 cm clearance. Native editor previews show the closed-in-rack, fully-clear, closed-in-view and raised-internals stages with another server already loaded. This is local rendering evidence; wearer acceptance of the timed controller sequence remains pending.

The chassis-first APK compiled successfully and installed with `adb install -r`. This update did not edit or delete saved model records. Headset acceptance remains with the wearer.
