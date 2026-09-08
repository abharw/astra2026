# Blender → USD → RealityKit: fidelity and processing audit

2026-09-08. This audit covers the pinned rack exterior and its build-time derivatives. It distinguishes serialized asset size, visible geometry cost, model-facing information, and native runtime performance.

## Finding and corrected candidate

Use the new **faithful v2** candidate for native acceptance before selecting it as the app default. It stores the exact source geometry and exact authored normals in **13,232,052 bytes**, down from **25,786,225 bytes**: a **48.7% package-size reduction without deleting a triangle**. Its only geometric correction is the independently reproduced PSU6 source offset. It avoids the visible server-panel distortion introduced by our earlier decimated derivatives.

This improvement uses ordinary **indexed USD normals**, not a proprietary mesh codec or an extra runtime SDK. Repeated normal vectors are stored once and referenced by integer indices. OpenUSD explicitly supports this representation to reduce repeated data. The processor verifies that expanding those indices reconstructs every source normal value and preserves its interpolation. [OpenUSD indexed primvars](https://openusd.org/release/user_guides/primvars.html#indexed-primvars), [mesh normals](https://openusd.org/release/api/class_usd_geom_mesh.html).

| Artifact | Bytes | Authored triangle equivalents | Expanded visible triangles | Fidelity boundary |
| --- | ---: | ---: | ---: | --- |
| Original Akeil exterior | 25,786,225 | 791,123 | 2,989,750 | Authored exterior; misplaced PSU6 |
| Earlier conservative derivative | 10,549,419 | 233,060 | 1,107,642 | Topology and shading regressions |
| Earlier distance derivative | 9,334,783 | 205,273 | 607,476 | Fine perforations contracted |
| **Faithful v2** | **13,232,052** | **791,123** | **2,989,750** | Exact topology and normals; corrected PSU6 |

The smaller file does **not** establish fewer GPU triangles, lower resident GPU memory, better frame rate, or faster first display. The 18 servers share one prototype, but all 18 remain visible, so their rendered triangle count is still multiplied by 18. Native measurement and screen-space LOD are separate work.

## Why the earlier simplification looked wrong

The conservative processor imported authored custom corner normals, marked all faces smooth, and passed those normals through Weld and Decimate. After vertices and faces changed, interpolated normals no longer described the final surface. On sampled large, nearly planar side triangles, 80.10% of the conservative surface area had a corner normal more than 10° away from the geometric face normal, compared with 11.23% in the source. The worst discrepancy was 175.55°. Source edge smoothing accounts for some nonzero original discrepancy; the derivative's much larger errors correspond to the diagonal bright bands in the rendered comparison. [Normal audit measurements](../evidence/mobile-rack-normal-audit.json).

Recomputing normals from final triangles fixes that shading error for an edited hard surface, but it cannot restore a hole or flat panel already changed by decimation. Flattening every normal would also degrade curved cables and rounded hardware. The faithful recipe therefore preserves the original surface and its original normals instead of applying another shading approximation.

Blender's Collapse mode changes shape as vertices merge; Planar mode dissolves edges according to an angular threshold and delimiters. Neither establishes a visual-error bound. In this CAD mesh, coplanar dissolve alone barely lowered the server triangle count because many triangles are required by perforation topology. A target number is not a fidelity criterion. [Blender Decimate documentation](https://docs.blender.org/manual/en/5.2/modeling/modifiers/generate/decimate.html).

## What the faithful build preserves

The independent validator passed for all **221 authored prim paths**, **38 meshes**, **18 server roots**, **18 internal instance references**, **one shared prototype**, **19 authored material prim paths**, and **48 material subsets**. Hierarchy, semantic properties, material connections, material assignments, transforms, UV data, face counts, face indices, and expanded normal values are retained. Polygon topology stays polygon topology; there is no unnecessary triangulation round trip.

Only the two known baked PSU6 point arrays receive world translation `[0, +0.4, -1.908]` metres. This is checked against the pinned source and independently reproduced authoring defect, not guessed from a screenshot. Bounds become approximately `[-0.3415, -0.5355, 0]` to `[0.3000, 0.5335, 2.2100]` metres. Source bytes remain unchanged. [PSU reproduction](../evidence/rack-psu-offset-reproduction.py), [intake](../evidence/asset-intake.json).

Fresh USDC export avoids retaining obsolete crate blocks. USDZ members remain uncompressed and 64-byte aligned. ZIP timestamps are canonicalized. Two complete builds on Blender **5.2.1 LTS**, build **9e2066aef7ef**, and bundled OpenUSD **0.26.3** produced the same SHA256:

`b1ae63bb5e95a52152dba08574b0e6b852ec9499fb1e0cf63360e96e3f31bad1`

This repeatability is measured on that toolchain, not guaranteed across future USD versions. The processor uses bundled `pxr`, NumPy, and standard Python; the faithful profile does not require fast-simplification or another installed package.

## Reproduce and inspect

```sh
python3 scripts/prepare-mobile-rack.py --profile faithful --correct-psu6 --render-comparison

/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python scripts/validate-mobile-rack.py -- \
  runtime/asset-source/datacenter-rack/models/lazy/rack-exterior.usdz \
  runtime/processed-assets/rack-exterior-faithful-v2.usdz --lossless
```

The candidate, build intermediates, native test catalog, and images are in ignored `runtime/processed-assets/`. The original and earlier variants are not overwritten. The explicit `faithful` profile fails closed if the source SHA differs.

| View | Original source | Faithful v2 |
| --- | --- | --- |
| Front | [Actual source render](../runtime/processed-assets/rack-exterior-faithful-v2-comparison/rack-source-front.png) | [Actual candidate render](../runtime/processed-assets/rack-exterior-faithful-v2-comparison/rack-mobile-front.png) |
| Rear | [Actual source render](../runtime/processed-assets/rack-exterior-faithful-v2-comparison/rack-source-rear.png) | [Actual candidate render](../runtime/processed-assets/rack-exterior-faithful-v2-comparison/rack-mobile-rear.png) |

These use identical 1000 × 1200 Blender Workbench cameras and lighting. Visual inspection shows the source's flat server panels and fine details retained, without the conservative derivative's diagonal highlight bands. The camera frames the intended rack; the original misplaced PSU is outside part of that frame. These images verify a Blender render, not RealityKit lighting or phone performance. [Build measurements](../evidence/mobile-rack-faithful-v2.json), [independent validation and repeated hash](../evidence/mobile-rack-faithful-v2-validation.json).

## The right model and runtime boundary

Blender remains an editable authoring source and offline compiler. USD carries render geometry, materials, and the authored hierarchy. Astra should manipulate a small semantic scene document: stable part identifiers, names, parent relationships, bounds, transforms, available detail levels, provenance, and supported operations. It should not receive millions of vertex numbers or regenerate an unchanged mesh to move a server.

For this exterior, moving `rack01.server03` should only update its semantic transform and the corresponding native entity. Reusing the server visual means reusing a geometry reference. Showing a generated airflow arrow should add a small procedural recipe alongside the imported server. Requesting real internal detail should load a separately exported component package and attach it to the existing server identity. A generated teaching diagram must remain distinguishable from an authored mechanical part.

The source exporter enables USD instancing and custom properties, which is a useful starting point. Its all-scene export is not the desired long-term packaging boundary. Keep independently useful assets separately loadable: rack structure, shared server exterior, and selected server interiors. Export by semantic ownership rather than by every CAD screw or by one flattened whole scene. Blender documents its USD export as a subset and instancing as an experimental export option; validate the resulting USD instead of assuming the Blender hierarchy survives unchanged. [Blender USD import/export](https://docs.blender.org/manual/en/5.2/files/import_export/usd.html).

The original sparse-clone `.blend` paths are Git LFS pointers. The parallel detail pipeline has separately verified `runtime/detail-source/parts-library.blend` at **137,229,178 bytes**, SHA256 `1d086d872ff4e795b795aed3400e5bac98fa7872bd26c84dc0877788be5ee4d2`, from the same pinned commit, and is exporting semantic interior groups. This exterior audit does not establish acceptance of those new packages. The pinned exterior itself contains no independently addressable motherboard, processor, or memory meshes. Appending the full detail library takes minutes in Blender, reinforcing the choice to perform that preparation before runtime rather than in the voice loop.

## Remaining performance work, in order

1. Accept the faithful indexed-normal package in RealityKit, including material appearance and selection, and measure cold load, warm load, resident memory, and first display separately.
2. Keep immutable mesh resources shared while retaining independent semantic server entities. Do not rebuild mesh or collision resources for transform, selection, or visibility changes.
3. Package rack frame and shared server exterior separately if measured startup improves. Load selected interiors only when requested; cancel or ignore stale completion after the target changes.
4. Add an explicitly reviewed distance LOD only after measuring screen-space need. At farther distances, fine perforations can be represented with baked textures or normal maps, but that requires UV/material work and loses actual holes; keep real geometry for close inspection and silhouettes. Do not silently substitute the earlier visibly degraded candidate.
5. Measure model tool payload and latency independently of mesh loading. Compact semantic handles and bounded operations improve model interaction; swapping geometry SDKs does not fix an oversized model context.

No new runtime SDK is justified by this audit. Indexed USD gives a large, measured byte reduction with exact source values. The next investment should be measured native loading and semantic detail packages, with triangle simplification treated as a controlled visual tradeoff.
