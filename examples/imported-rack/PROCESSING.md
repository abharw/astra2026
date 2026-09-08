# Rack build-time derivatives

The default candidate is `runtime/processed-assets/rack-exterior-mobile.usdz`, using the **conservative** profile. The optional `rack-exterior-distance.usdz` profile reduces geometry further, with visible loss of perforation detail. Neither is a close-up replacement for the original asset or its Blender detail libraries.

| Asset | USDZ bytes | Authored triangles | Expanded visible triangles | Triangles per shared server |
| --- | ---: | ---: | ---: | ---: |
| Pinned source | 25,786,225 | 791,123 | 2,989,750 | 129,331 |
| Conservative, default | 10,549,419 | 233,060 | 1,107,642 | 51,446 |
| Distance, optional | 9,334,783 | 205,273 | 607,476 | 23,659 |

“Expanded” counts the server mesh 18 times, plus 181,614 rack triangles in either derivative. The source contains polygons; its triangle equivalents are `sum(faceVertexCount - 2)`. Derivatives are explicitly triangulated. Geometry counts do not establish GPU time, memory, or device frame rate.

## Reproduce

Run from the Astra repository root after obtaining the pinned source described in [the intake review](../../docs/imported-rack-review.md). The pipeline fails closed if the input SHA differs. It does not download the large interior Blender libraries or alter the source.

Tested toolchain: Blender **5.2.1 LTS**, build **9e2066aef7ef**, bundled OpenUSD **0.26.3**, bundled Python **3.13** and NumPy. The conservative build needs no additional package. The optional distance profile uses [fast-simplification](https://github.com/pyvista/fast-simplification) **0.1.13**; its macOS ARM wheel was 221 KB.

```sh
python3 scripts/prepare-mobile-rack.py --profile conservative --correct-psu6 --render-comparison

/Applications/Blender.app/Contents/Resources/5.2/python/bin/python3.13 -m pip install \
  --target runtime/processed-assets/python-deps --no-deps fast-simplification==0.1.13

python3 scripts/prepare-mobile-rack.py --profile distance --correct-psu6 \
  --output runtime/processed-assets/rack-exterior-distance.usdz \
  --evidence evidence/mobile-rack-distance.json --render-comparison

/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python scripts/validate-mobile-rack.py

/Applications/Blender.app/Contents/MacOS/Blender --background --factory-startup \
  --python-exit-code 1 --python scripts/validate-mobile-rack.py -- \
  runtime/asset-source/datacenter-rack/models/lazy/rack-exterior.usdz \
  runtime/processed-assets/rack-exterior-distance.usdz
```

Use `--blender`, `--input`, `--output`, `--evidence`, and `--python-deps` for other local paths. `--server-triangles` and `--rack-ratio` expose the recipe budgets; changing them requires new visual review. The source SHA pin is intentional. Changing the source requires reassessing source metadata and the PSU correction, rather than bypassing the pin.

The build processes one copy of each authored mesh. It exports a fresh compact USD crate, packages USDZ, and canonicalizes ZIP timestamps to 1980-01-01 while retaining USDZ entry alignment. Full repeat builds of both final profiles produced identical hashes. This was verified on the pinned toolchain, not promised across Blender versions or architectures.

## Preserved structure and correction

Both variants retain all **221 prim paths**, **38 authored meshes**, **18 independent server roots and instance references**, one shared server prototype, all material bindings and **48 material subsets**, all source transform operations, source provenance attributes, **Z-up**, and **metersPerUnit = 1**. There are 17 shader/material definitions plus two material prims within the shared prototype, giving 19 authored material prim paths. No mesh is joined across a semantic part. Unused cable UV arrays are removed after topology changes; the pinned source has no image textures.

The server prototype is authored below the undefined `/root/prototypes` scope, which ordinary USD traversal excludes. The recipe and validator include it explicitly. A server's transform, visibility, or subtree can be changed independently; editing shared mesh vertices requires first making that server's geometry unique. See [OpenUSD scenegraph instancing](https://openusd.org/release/api/_usd__page__scenegraph_instancing.html).

`--correct-psu6` translates only the two baked PSU6 mesh point arrays by world-space `[0, +0.4, -1.908]` metres. No semantic transform changes. The pinned source authoring script was independently rerun with one missing dependency-graph update added: all 30 PSU6 source objects received this correction, while all 150 objects belonging to PSU1–5 stayed unchanged. See [the measured intake evidence](../../evidence/asset-intake.json) and [the reproducer](../../evidence/rack-psu-offset-reproduction.py). This fixes the source's floating PSU; the final rack height is about 2.21 m. The upstream asset remains untouched.

## Fidelity and acceptance limits

The conservative recipe welds coincident vertices within 10 micrometres, dissolves coplanar faces within 0.5 degrees, then applies Blender Decimate. Labels and meshes below 1,000 triangles are retained. The shared server contains thousands of perforation holes; Blender's topology constraints stop at 51,446 triangles despite an 18,000 requested budget. Preserving that extra topology is the reason this profile remains the default candidate.

The distance profile simplifies each server material region independently with the pinned quadric simplifier, retaining small material regions and contracting some fine holes. It uses normals of the resulting surface, because transferring tiny hole-wall normals onto larger faces created misleading highlights. Its 22,000 requested server budget yields 23,659 actual triangles. The rendered rack still has visible faceting and loses fine perforation detail; use it only as an optional distance LOD.

The conservative render retains more of the perforation pattern, but side panels and rounded rack elements still show shading changes. Neither variant has been established as visually equivalent to the source. Identical-camera, 1000 × 1200 Blender Workbench renders are generated from the actual imported source and derivative geometry:

- [Conservative source, front](../../runtime/processed-assets/rack-exterior-mobile-comparison/rack-source-front.png) · [Conservative derivative, front](../../runtime/processed-assets/rack-exterior-mobile-comparison/rack-mobile-front.png)
- [Conservative source, rear](../../runtime/processed-assets/rack-exterior-mobile-comparison/rack-source-rear.png) · [Conservative derivative, rear](../../runtime/processed-assets/rack-exterior-mobile-comparison/rack-mobile-rear.png)
- [Distance derivative, front](../../runtime/processed-assets/rack-exterior-distance-comparison/rack-mobile-front.png) · [Distance derivative, rear](../../runtime/processed-assets/rack-exterior-distance-comparison/rack-mobile-rear.png)

The framing targets the actual rack at 1.15 m with a 2.9 m orthographic scale; the raw source's misplaced PSU is above that frame. The separate bounds/reproduction evidence establishes its correction. The renders are not RealityKit performance evidence.

The reports include deterministic vertex-to-surface samples in both directions. Samples include original unused vertices and precede the separately documented PSU correction. They do not establish a Hausdorff bound or preserve tiny openings. The conservative server's source-to-output p99/max were 5.24/29.51 mm; distance p99/max were 3.72/11.95 mm. The lower distance-profile numbers do not mean better visual fidelity: material appearance and perforation loss require the render comparison.

The structural validator separately verifies material shader properties and connections, all original semantic attributes and transforms, 18 internal references, complete material-subset coverage, geometry/normal domains, finite data, mesh extents, uncompressed USDZ members, and 64-byte alignment. Device import and rendering acceptance remain separate. The mechanical, motherboard, memory, and processor-study `.blend` libraries have **not** been converted into native detail assets.

## Provenance and hashes

Upstream: [abharw/astra2026, commit 051c9d954292438fc8419661aa91451367961d86](https://github.com/abharw/astra2026/tree/051c9d954292438fc8419661aa91451367961d86/datacenter-rack). Keep the [copied license notices](licenses/README.md), source attribution, and the derivative preparation script with redistribution; the notices distinguish permissive Zaius material from the reciprocal authored rack reconstruction. They do not relicense application code.

- Source SHA256: `aa98a44a29ab27c7e81116ba0340ad52b9a00e03516ad7ed6f7bf3de9ba0a6ba`
- Conservative SHA256: `685fb4717cd6209bbb7ecc9a9e993c4d124fa5860958ae0d650215e155a3d84b`
- Distance SHA256: `fae0a2926ef61542fef27dc1d85d992211da6bef4fccf5b1cce3b8b252626974`

[Mobile manifest](mobile-manifest.json), [conservative measurements](../../evidence/mobile-rack-processing.json), [distance measurements](../../evidence/mobile-rack-distance.json), and [validation receipts](../../evidence/mobile-rack-validation.json) are lightweight tracked records. USDZ binaries, dependency wheels, intermediary crates, and rendered images remain in ignored `runtime/processed-assets/` and can be reproduced with the commands above.
