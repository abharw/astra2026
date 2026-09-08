# Editable rack cable harness

`source/rack_cabling.py` adds independent Bezier cable objects and accessory meshes. It does not clear scenes, change imported source objects, render, fetch files, or change other authoring modules.

```python
import rack_cabling
harness = rack_cabling.build_cabling(
    rack['server_slot_origins'], parent=rack['root'],
    patch_panel_ou=39,
    internal_ous=[1],
    include_internal_power=True,
)
```

The return value contains `root`, `collection`, `objects`, `curves`, `external_curves`, `internal_curves`, `endpoints`, and `metadata`. Coordinates are SI metres in the integrated rack frame. Only supplied odd slots OU1 through OU35 receive external cables. There are eighteen management cables with the complete standard slot map, plus a generic passive 36-position patch panel at OU39. It is not an active network switch and has no invented vendor or SKU.

## Source-bound endpoints

The builder reads the local `research/pcb-population/population-source.json` and `models/barreleye-evt-mesh/assembly.json`. It joins actual reference designators and CAD occurrence records, and records source hashes in its returned metadata.

- **LAN1** is at ODB `(123.89993, 6.469888)` mm. With motherboard alignment `(-.228, .00313, .0105)` m, its rack X position is `-.10410007` m. The EVT3 schematic's sheet140 explicitly identifies LAN1 Port A with BCM54612E and the BMC PHY path; Port B goes to BCM5719A. The exact plug mouth uses the integrator-supplied conceptual height of `.026` m above slot base and a reconstructed front-face offset at `equipment_front_y - .006`. The ODB position is evidence; the visible connector mating plane remains an inference.
- **J27** is the source motherboard 48 V input, ODB `(24.158956, 537.969968)` mm, with `20.999958` mm EDA height. Schematic sheet250 identifies Molex42819-4233. Its inferred wire endpoint is at the package top.
- **CAD node-09930** is `2204793-2CVM_1208`, the rear busbar connector region. The builder composes the actual source occurrence matrices and transforms its bounding center using `(old X, -old Z, old Y) + slot_origin`. The first-slot center is approximately `(0, .39905003, .2115)` m. The black internal harness joins that region to J27, with route and exit placement explicitly reconstructed. This is not exact mating-contact geometry or a pin-level wiring claim.

`internal_ous` defaults to the first supplied slot, keeping one detailed internal example. Pass additional supplied slots to create their individual power harnesses, or set `include_internal_power=False` when the integrator needs to defer collision/mating review.

## Internal data boundaries

No extra internal data cable is guessed from shell shape. The mechanical source already contains an HDMI cable (`node-02074`) and a VGA cable body (`node-02215`), which this module leaves intact. Source schematic evidence identifies the SAS-style J28/J30/J31/J33 shells as **CP0/CP1 NVLINK top/bottom**, so those parts are not relabeled as storage ports. J14 is a source SATA22 connector, but a new cable's actual counterpart and route were not established in this bounded pass.

The builder accepts `internal_data_routes=[record, ...]` when the integrator supplies established endpoint pairs. Each record must include `name`, `points` (rack-coordinate control points), `endpoint_from`, `endpoint_to`, `source_url`, and `description`; optional `radius` defaults to `.002` m. Such records create separate editable Bezier curves and retain the provided source attribution. This interface does not silently select or invent counterparts.

## Appearance and editing

Every management cable is one named curve with child plug bodies, latch tabs, eight gold-colored contact representations, strain-relief ribs and an OU tag. Select the curve to move/hide the entire cable with its plugs, or use Rack Lab → **Edit cable route points** to modify its Bezier control points. Move a plug child individually for an unplugged pose, then edit the route endpoint to follow it. No cable physics or automatic connector constraint is implied.

The royal-blue 5.1 mm jacket diameter, simplified plug proportions, 36-port panel layout, clip dimensions, bend shapes and service slack are visual reconstruction choices. No EIA/TIA dimensional or electrical compliance is claimed. The internal power jacket is black; hidden conductor assignment was not invented.

Each curve stores `endpoint_from`, `endpoint_to`, `evidence_level`, source URL, route status, jacket diameter and the original control-point coordinates. The top panel is a passive inferred management patch panel. Endpoints identify the intended occurrence and port, rather than implying a live network connection.

## Validation and remaining integration check

`logs/cabling-smoke.py` builds the unchanged rack module and new cabling in a fresh background Blender scene. Seven checks passed: eighteen external cables, 36 patch positions, editable Bezier curves, endpoint metadata, inference tags, external control points in front of the chassis datum, and finite coordinates. The built module has 792 objects and nineteen cable curves with default settings. Three Workbench previews were rendered and visually inspected: `cabling-front.png`, `cabling-patch.png`, and `cabling-port.png`.

The external route points run forward of the chassis datum with the vertical bundle outside the rack's left edge. This geometric arrangement and the isolated rack preview do **not** prove clearance against the full imported server. The actual jack mouth and internal 48 V route still require integrated visual/collision review. No new source `.blend` or shared scene was written by this cable pass.
