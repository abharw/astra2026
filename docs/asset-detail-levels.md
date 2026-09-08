# Choose the smallest useful subtree

Astra should manipulate an asset's existing hierarchy at the depth the question requires. A request to pull out all server units changes the transforms of those intact instances. Explaining one selected unit needs that instance's context and a summary of its children. It does not imply exploding every child, loading every mesh, or editing the asset template shared by the other instances.

These are operations on **arbitrary parent/child relationships**. Rack, server, fan and processor are vocabulary in this example's data, not universal framework levels. A lamp, engine, cell or building must supply its own hierarchy. Visual mesh detail and semantic depth are independent: a detailed mesh can remain one semantic object, and a simple box can represent an assembly with many meaningful children.

## Three representations with separate jobs

1. **Editable source:** Blender collections, source CAD hierarchy, source materials, occurrence metadata and evidence. Preserve this as the reproducible authoring input.
2. **Render resources:** USDZ meshes coalesced inside configured manipulation boundaries. Multiple physical instances may share these immutable resources. Runtime transforms and selections belong to instances, not the shared template.
3. **Semantic manifest:** IDs, parents, descriptions, bounds, rest transforms, current resource bindings and available child resources. This is the model-facing representation. Vertices, thousands of passive-component records and material arrays are unnecessary in the normal conversation.

OpenUSD already distinguishes models, assemblies and subcomponents as useful traversal boundaries. Its payloads support deferred composition, while references and instances share reusable source structure. Those are useful authoring concepts; they do not establish that RealityKit exposes OpenUSD's working-set API. Our native application explicitly loads approved resource packages and installs their semantic children. [OpenUSD kinds](https://openusd.org/release/api/kind_page_front.html), [working sets and payloads](https://openusd.org/release/glossary.html#payload).

Blender's USD exporter writes a subset of USD and supports selected-object export and custom properties. It is an interchange exporter, not the interaction protocol or a complete USD composition editor. Compilation happens before a conversation; Astra changes the compact semantic scene at runtime. [Blender USD exporter](https://docs.blender.org/manual/id/5.0/files/import_export/usd.html).

## What the supplied source actually contains

The source is pinned to `abharw/astra2026` commit `051c9d954292438fc8419661aa91451367961d86`, directory `datacenter-rack`. The exterior USDZ has 18 independently identifiable server roots; each exterior's inner geometry is joined. Internal parts cannot be recovered from that surface merely by assigning names.

The separate `parts-library.blend` was downloaded and verified against its Git LFS digest:

| Resource | Bytes | SHA-256 |
|---|---:|---|
| `parts-library.blend` | 137,229,178 | `1d086d872ff4e795b795aed3400e5bac98fa7872bd26c84dc0877788be5ee4d2` |
| `part-knowledge.json` | 24,939,668 | `0940cb2149a4bccee6ae5158c1725361a07f66bd9ce1464ce6999b061acb3ec2` |

The source manifest provides four collections: mechanical detail (1,929 objects), motherboard (7,042), memory (10,336), and an explanatory processor study (246). An actual Blender binary inventory confirmed those counts: 19,076 meshes, 416 transform empties, 60 text objects and one curve across the collections. Counts include shared ancestors; they are not runtime draw calls. Component knowledge contains 21,194 records without requiring geometry load. [Pinned manifest](https://github.com/abharw/astra2026/blob/051c9d954292438fc8419661aa91451367961d86/datacenter-rack/models/lazy/manifest.json), [source integration contract](https://github.com/abharw/astra2026/blob/051c9d954292438fc8419661aa91451367961d86/datacenter-rack/docs/AGENT_USAGE.md).

The source's detailed motherboard and memory collections are too broad for the first educational overview. Appending the full library also performs expensive Blender ownership conversion. A local process sample showed `BKE_lib_id_make_local_generic` traversing many property and ID references for more than five minutes. The compiler instead links the source read-only and copies only output geometry into new local meshes. This changes the offline compiler, not the source library.

## Sample grouping is data

[teaching-groups.json](../examples/imported-rack/teaching-groups.json) configures the current example's nine manipulation boundaries: chassis, storage, cooling fans, processor/socket assemblies, processor heatsinks, motherboard, memory, network adapter and power input/conversion. The compiler follows configured source ancestry and collection membership. It has no prompt keywords, fixed hardware hierarchy or hidden model routing rules.

[export-asset-groups.py](../scripts/export-asset-groups.py) writes one pack with independently named group roots, a resource catalog, a portable semantic manifest and a source-membership index. All source object transforms are baked into the original asset-local basis; each group's geometry is centered at its own bounds and its rest translation restores the authored position. The source index retains the IDs represented by each merged group. Coalescing happens **inside** the configured manipulation boundary; it does not join the whole scene into one uneditable mesh.

The source-derived server pack has been compiled and independently reopened with OpenUSD: **nine group roots, 381,897 triangles and 8,226,964 bytes**. The build took 377.16 seconds before the final storage pass. Seven groups met their configured triangle targets; storage and power exceeded theirs because Blender's collapse step could not simplify the remaining topology sufficiently. See [the build receipt](../evidence/server-detail-processing.json). Native selected-instance detail installation is now covered by the macOS controller probe; physical-device performance and interaction remain unverified.

A format-only pass indexes repeated normal values, reducing the compiled pack from 17,178,641 to 8,226,964 bytes. It verifies identical points, topology, normal interpolation and expanded normal values before accepting the result. This lossless storage pass does not undo the earlier, explicitly approximate mesh simplification, and does not prove reduced GPU work. [asset_usd.py](../scripts/asset_usd.py) is shared format code with no rack-specific rules.

The sample recipe omits individual memory contacts and objects smaller than 2.5 mm from its overview representation. Its triangle budgets and material policy are explicit build choices, not proof of fidelity or device frame rate. The original source remains available for later more detailed exports. The output uses untextured PBR material values; it does not claim to preserve fabrication texture maps.

The compiler's JSON recipe is reusable. A non-rack lamp fixture exercises different IDs, nested source ancestry and grouping through the same compiler. Its output has three groups, 112 triangles and approximately 5.6 KB; the check verifies source IDs, world bounds, root names, parents, units and digests. See [the fixture receipt](../evidence/asset-group-fixture.json). This tests interchange and identity, not native rendering.

Run the offline compiler against the verified source binary:

```sh
python3 scripts/export-asset-groups.py \
  --recipe examples/imported-rack/teaching-groups.json \
  --input runtime/detail-source/parts-library.blend
python3 scripts/prepare-selection-proxies.py
python3 scripts/check-asset-group-compiler.py
```

Build outputs remain under ignored `runtime/processed-assets`; compact manifests and validation receipts are checked in. The compiler validates the source digest before opening Blender data and validates exported group identities and triangle totals afterward. Runtime delivery must use its approved catalog and digest rather than the compiler's local file URL.

## Interaction boundaries can be smaller than a render group

A single bounding box around all memory modules covers the empty processor gap. A box around the chassis covers almost every internal group. Those boxes make pointing inaccurate even if the rendered meshes and semantic hierarchy are correct.

The optional selection policy is separate from rendering and meaning. It can disable selection for an enclosing group or provide several small boxes that all resolve to that group's same semantic ID. The sample recipe identifies source clusters; [prepare-selection-proxies.py](../scripts/prepare-selection-proxies.py) derives their actual represented geometry bounds in prototype-local coordinates. The script has no hardware-specific names or rules.

The current sample uses 76 boxes: 24 storage carriers, six fan modules, two processor/socket assemblies, two heatsinks, one network adapter, nine power clusters and 32 memory modules. Chassis and motherboard are non-selectable through these proxies. Geometry and digest are unchanged. [Selection evidence](../evidence/server-selection-proxies.json) records every source cluster and its bounds. Native ray selection remains a separate check; proxy construction alone does not prove that a user's finger selects the intended visible part.

## Instance context and detail installation

A model-facing view should include the selected instance and its ancestor path; the current posed transform; the authored rest transform; the IDs and descriptions of immediate children; which children are loaded; which resources are actually available; bounds; and provenance. Keep exact source CAD IDs, BOM reference designators, hashes and material data behind a bounded lookup. “Exists in the source library” and “can be loaded by this app now” are distinct states.

Loading detail must preserve the selected instance ID and current pose. It must not call the existing whole-scene import operation, which replaces the document. The application prepares approved resource data asynchronously, validates its digest, then installs children under that instance as an accepted scene change. The model receives a receipt before saying those children are visible. A stale or cancelled load cannot install into a different scene or selection.

For this example, the existing native server wrapper already contains the source-to-RealityKit basis rotation `R = rotationX(-π/2)`. Blender detail remains in the original server-local Z-up basis, measured in metres. RealityKit adds `R` on import. Therefore an extracted detail part's imported world transform must be converted to a source-local child transform before attaching to that wrapper:

```text
childLocal = inverse(R) × importedPartWorld
childWorld = currentServerWrapperWorld × childLocal
```

The semantic manifest records the basis and each group's source rest transform. A generic installer derives this from resource and target binding metadata; it must not hardcode “rotate server by 90 degrees.” Translation, rotation and scale already applied to a selected instance must remain intact. Do not add the original rack-slot translation again.

## Evidence boundaries that must survive the pipeline

- The detail library omits the removable cover. It supports replacing the closed exterior with the open interior. It does not support detaching an authored lid unless that separate source is exported.
- The selected source configuration excludes alternate and duplicate CAD variants. The compiler reads the selected library rather than expanding the original multi-variant CAD tree.
- Memory modules are supported-class analogues at source socket positions. Their exact fitted SKU or capacity is not established.
- Processor/socket geometry and the separate POWER9 architectural illustration are different resources. The illustration's cores, caches and contacts are explanatory, not a recovered physical die layout.
- Source component identity is not live telemetry, electrical simulation, serial-number inventory or proof of installed hardware. [Source component guide](https://github.com/abharw/astra2026/blob/051c9d954292438fc8419661aa91451367961d86/datacenter-rack/docs/COMPONENT_GUIDE.md).

Acceptance requires an intact-instance move with no detail resource load; a selected-instance reveal that preserves all other instances; a follow-up operation on a revealed child; restoring the parent without losing its identity; matching rendered and semantic transforms; and independent cancellation of a stale resource request. Exported bytes and unit tests alone do not establish those native behaviors.

## Current implementation status

The generic detail path is now implemented in the native controller and app catalog. `DemoAssetLibrary` registers host-approved templates for eligible instances and lazily matches the selected instance to a bundled detail resource. `expandDetail` preserves the target node ID, parent, current pose, visibility and unrelated instances, then installs the approved immediate children through the existing patch, receipt, Undo and cancellation fences. The passed macOS probe expands one of 18 instances from 20 to 29 nodes, adding nine children from the detail asset `sha256:0a026a5d4b06577b25d334dbca7a8e84bca8af0fe169e12be25099bb2740f4e0` (8,226,964 bytes; 381,897 triangles). This is native controller evidence, not physical-device performance or pointing acceptance. Arbitrary hierarchy bindings and lamp fixtures are covered by the generic tests; there are no fixed rack/server/processor levels.
