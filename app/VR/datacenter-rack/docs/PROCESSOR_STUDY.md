# POWER9 processor study

`source/processor_study.py` builds a separate explanatory processor assembly at the supplied parent's local origin, in meters. It does not replace source CAD or alter the rack configuration.

```python
from processor_study import build_processor_study, set_exploded
root, metadata = build_processor_study(collection, parent=None)
set_exploded(root, 1.0)  # separated view
set_exploded(root, 0.0)  # return to schematic assembled positions
```

The 68.5 × 68.5 mm package body, 695 mm² die area, 3899 contacts, 1.016 mm hexagonal land pitch and 7-2-7 organic package construction come from IBM POWER9 LaGrange v1.7, pages 19/77. The module includes a square die of the documented area; its aspect ratio, thickness and orientation are schematic. The source pin list provides identifiers and signals but the separate mechanical placement drawing was not acquired. Consequently only 144 symbolic contact markers are drawn, prominently labelled as symbols; their positions and spacing are not asserted to match actual lands.

Sixteen selectable diagram bands explain 7-2-7 construction. They are not a reconstruction of measured laminate thickness, conductor cross-section or actual wiring. The CMOS 17-metal-layer technology specification describes on-die fabrication and is distinct from this package substrate construction.

The functional die view contains 24 selectable core tiles, 12 L2 tiles, 12 L3 regions, interconnect and memory/I/O tiles. Counts and relationships follow IBM's architecture presentation; layout is deliberately explanatory. The 24-core drawing shows maximum SMT4 capability. The actual installed part's enabled core count, ordering code and stepping are not established. The 120 MB/12-region L3 architecture comes from the Hot Chips 2016 presentation page 4; the external interface labels use the LaGrange package-specific eight DDR4 interfaces, 42 PCIe Gen4 lanes, two 25G bricks and two X buses from the datasheet, rather than the generic chip's 48-lane capability.

The thermal interface and heat spreader illustrate the heat path. Their exact LaGrange shapes, thicknesses, plating and interface compound are unverified. Every semantic object has a unique `part_id`, `function`, `description`, `source`, `evidence_level` and `geometry_origin` property for selection and inspection. Surface colors are teaching choices.

Sources are retained under `research/components/originals/`. No screenshot or copied die illustration is embedded in the deliverable geometry. The first verification is an isolated headless Blender scene under `research/cad-diagnostics/processor-study-validation.blend`; integrated rack placement and final visual review remain the integrator's responsibility.
