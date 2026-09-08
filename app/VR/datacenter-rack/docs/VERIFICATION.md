# Verification and remaining work

## Packaged asset

The delivered exterior is 11.2 MB with one rack, 18 server roots, 80 objects, 21 mesh datablocks and zero detailed collections. The detailed library is about 137 MB (decimal); the full authoring master is about 139 MB. Exact generated sizes/counts are in `models/lazy/package-receipt.json` and `models/asset-finish-receipt.json`.

## Actual running Blender session

The finite question bridge operated on the packaged model in a live Blender 5.3.0 Alpha process:

| Operation | Observed result |
|---|---|
| Show CPU in server 3, first request | Only processor collection appended; 1.23 s; 326 total objects / 94 meshes |
| Repeat the CPU request | Cache hit; 0.021 s; no added geometry |
| Back to rack | Exterior scene restored; detail retained in cache |
| Unload processor | Returned to 80 objects / 21 meshes / zero loaded detail |
| Show U14 in server 3 | Only motherboard collection appended; selected `pcb.U14`; identified ASPEED AST2500; about 120 s first load |
| Unload motherboard | Imported detail released; see `logs/live-unload-motherboard.json` for final counts |

The initial CPU receipt is retained in the sanitized command logs. Subsequent structured results are in `logs/live-*.json`. These are real in-process geometry operations, not resolver-only tests. They prove the local bridge path. Native sidebar click-through on the final packaged window was not completed: computer use targeted a separate earlier Blender process. No claim of final GUI/button or headset acceptance follows from the bridge receipts.

## Focused checks

The isolated lazy-inspector suite has 44 assertions covering demand loading, cache sharing, part selection, save/reopen, hot reload, rack/server editing and cleanup. Question-context tests cover source/refdes/MPN resolution, unknown and ambiguous cases, source levels and bounded responses. The selected source CAD has zero unresolved nonzero missing faces after accepted tessellation repairs, with analytical-vs-mesh bounding endpoint disagreement below 0.000305 mm. Bounds agreement is not a surface-distance or real hardware measurement certificate.

The GLB contains 92 nodes, 38 meshes and all 18 server identities, with no internal-detail IDs. The USDZ archive passed integrity validation. See `models/lazy/interchange-validation.json`. Coordinate contracts are recorded in the manifest. The default exterior beauty image was rendered from actual saved geometry and inspected. Further detail renders were stopped at the user's request; no render is needed to use the library.

## Remaining product work

- Optimize first motherboard append latency and measure multiple-rack memory/frame time.
- Complete native sidebar click-through with the final packaged model.
- Export desired detail collections into the target engine's runtime format and implement that engine's lazy-loader/disposal behavior.
- Integrate voice or a live language model if desired; the included fallback resolver is deterministic and the bridge executes finite intents.
- Validate headset interaction, visual scale, selection, comfort and performance on the actual device; add physics/robot behavior only with explicit validation.

The current deliverable is the complete saved Blender asset library, its working local lazy-loading/question bridge, exterior interchange exports, source pipeline and audit trail.
