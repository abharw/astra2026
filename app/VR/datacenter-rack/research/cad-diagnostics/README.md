# Source CAD diagnostics

Source STEP sha256: `823c119e2f7eebae3eda204590c4e6d54e0b990a43e4406987e476bbf41813a1`.

All 273 missing topological faces reproduce at the converter's 0.05 mm linear / 0.16 rad angular deflection. Of these, 231 have numerically zero area (absolute signed surface integration below 1e-8 mm²); these do not imply visible holes. Their original topological definitions and source-face BREP hashes are retained. Fifteen nonzero faces tessellate successfully at 0.005 mm / 0.08 rad (14 faces) or 0.00005 mm / 0.02 rad (one selected planar face) on isolated, unchanged source face copies. The accepted patches are valid and their native BREP bounds are exactly unchanged. Controlled ShapeFix_Face with precision and maximum tolerance 1e-7 mm does not resolve the remaining 27 faces, nor does 0.0005 mm / 0.04 rad tessellation. No fabricated fill was added.

The 42 nonzero faces sum to 6.696160759 mm² in absolute signed surface integrals. The 27 unresolved faces sum to 5.774957340 mm². These are integration diagnostics on source faces, not a screen-visible hole-area measurement; some invalid/self-intersecting source faces have negative signed integrals. Counts and areas are per unique definition, not occurrence-weighted.

| Definition | Missing | Numerical zero | Repaired | Unresolved | Absolute integral mm² |
|---|---:|---:|---:|---:|---:|
| def-00000 | 24 | 24 | 0 | 0 | 0 |
| def-00103 | 142 | 142 | 0 | 0 | 4.57649012e-12 |
| def-00186 | 2 | 0 | 2 | 0 | 0.874071813 |
| def-00393 | 16 | 12 | 4 | 0 | 0.00293401496 |
| def-00394 | 10 | 2 | 0 | 8 | 1.94953042 |
| def-00396 | 11 | 5 | 0 | 6 | 1.67102534 |
| def-00398 | 11 | 5 | 0 | 6 | 1.67102534 |
| def-00402 | 2 | 2 | 0 | 0 | 0 |
| def-00403 | 9 | 7 | 2 | 0 | 0.00144241509 |
| def-00404 | 8 | 8 | 0 | 0 | 2.69839706e-13 |
| def-00428 | 1 | 0 | 1 | 0 | 0.00042051712 |
| def-00499 | 12 | 6 | 0 | 6 | 0.482669113 |
| def-00501 | 18 | 13 | 4 | 1 | 0.00358798309 |
| def-00593 | 1 | 0 | 1 | 0 | 0.0295374165 |
| def-00597 | 1 | 0 | 1 | 0 | 0.00991638253 |
| def-00696 | 5 | 5 | 0 | 0 | 2.77666345e-13 |

Among unresolved faces, 20 are invalid under BRepCheck_Analyzer and 7 pass it but still fail tessellation. See per-face wire diagnostics, surface type, UV ranges and status flags in `missing-face-baseline.json`; corrected per-face bounds are in `repair-report.json`. OCCT8 mesher flags decode as1=open wire,2=self-intersecting wire,4=failure,8=remesh,16=unoriented wire,32=too few points,64=outdated,128=reused. A bit can describe another face in the same definition, so whole-definition flags do not prove an individual face's cause.

`repaired-meshes/` contains seven complete derivative NPZ files preserving the original vertices, triangles, material indices and palette as exact prefixes, verified with NumPy array equality. Added 15 faces contribute 1519 triangles. OriginalSTEP/converter/mesh package remain unchanged. `repaired-mesh-receipts.json` contains source and derivative hashes; `patches/` keeps each added face separate for audit.

`cpu-material-map.json` maps all24source heatsink child definitions to the inspected Furukawa drawing. CAD names identify copperblock, fins, pipes and aluminum base; unlabeled socket compound material splits remain unverified.

Independent source traversal and analytic-versus-actual-mesh bounds passed and are reported in `bounds-validation.json` and `selected-bounds-validation.json`. Bounding agreement does not prove surface Hausdorff distance or exclude missing interior faces.

## Selected configuration

For `evt3-2ou-no-gpu-25gbe-furukawa`, after integrating the finalized replacement files for def-00186, def-00593 and def-00597, zero unresolved nonzero faces remain. Sixty-four affected face occurrences are restored (2 faces × 8 occurrences, plus 24 + 24). The selected chassis still reports 24 numerically zero-area topological faces. Excluded NIC alternatives account for the remaining source-library nonzero failures. `selected-configuration-defects.json` records the configuration fingerprint and counts.

The final def-00186 planar face needs finer tessellation only, no healing: the valid source face bounds are exactly unchanged, and mesh area is0.297559732mm² versus native0.297577249mm², a0.00589% integration difference. `final-selected-face-receipt.json` records the source and patch hashes.

## Reproduce

From `datacenter-rack/`, use `../.cad-venv/bin/python` for the following entrypoints in order:

1. `scripts/diagnose_cad.py --stage baseline`
2. `research/cad-diagnostics/repair_missing_faces.py`
3. `research/cad-diagnostics/final_selected_face.py`
4. `research/cad-diagnostics/finalize_derivatives.py`
5. `research/cad-diagnostics/validate_assembled_bounds.py`

The first entrypoint verifies the source hash and uses the pristine XCAF cache when available. Bounds of rotation-transformed native BREP definitions are cached incrementally; translation is applied after bounding. This avoids repeating identical source geometry work and never transforms AABB corners. Native empty placeholders are counted separately. `actions.jsonl` and individual `run-*.log` files retain operation outcomes and errors.

## Measured native-to-mesh bounds

Independent XCAF traversal matched 9940 nodes and 8741 leaf occurrences. All local translation components agree exactly; maximum rotation coefficient difference is 1.11e-16. Twenty-one empty source definitions have void bounds and no surface mesh. Analytic bounds are computed on actual rotation-transformed native BREP, then translated. Vertex bounds include every actual instance vertex, never rotated bounding-box corners.

| Scope | Mesh occurrences | Source extents X/Y/Z (mm) | Maximum endpoint error X/Y/Z (mm) |
|---|---:|---|---|
| Full multi-option source | 8720 | 545.359457869, 318.639536893, 1383.806712026 | 0.000304592633, 0.000000460919, 0.000000475242 |
| Selected configuration with repaired meshes | 2022 | 545.359457869, 92.700000100, 928.806712026 | 0.000304592633, 0.000000152737, 0.000000475242 |

The largest selected source-to-mesh bound endpoint difference is below 0.000305 mm. These are numerical source-CAD comparisons, not physical caliper measurements and not a full-surface Hausdorff-distance certificate. Selected bounds cover source CAD only; separately authored PCB population and explanatory processor study are outside that comparison.
