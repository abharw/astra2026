# Open Rack V2 frame and 48 V power module

Owner: rack-frame/power specialist. Integrator: root task. Created 2026-09-08.

`source/rack_frame.py` builds an editable Blender assembly. `source/rack-frame.blend` is the standalone source checkpoint. This is an authored reconstruction of published hardware interfaces, not a manufacturer-certified one-to-one digital twin. The unresolved deep-rack busbar mating is a material integration gate.

## Interface

```python
import rack_frame
result = rack_frame.build_rack({
    'equipment_front_y': -0.400,
    'support_ous': [1, 3, 5, 7, 9],
    'power_shelf_ou': 37,
})
```

The function performs no global scene deletion, lighting setup, render, or unit changes. It returns:

- `root`: `rack.assembly`, floor origin `(0,0,0)`.
- `collections`: structure, retention, supports, hardware, power, labels.
- `server_slot_origins`: integer OU numbers → front/bottom/center chassis coordinates. OU1 is `(0,-0.400,0.180)`; add 0.048 m per OU. These are placement datums, not prevalidated placements of the source server CAD.
- `metadata`: config, dimensional sources, unresolved reconstruction gates.
- `anchors`: busbar front surfaces, shelf output blade ends, AC inlet positions and NAC Ethernet position; each includes position, axis, part name and evidence level. These are visual attachment datums, not proof of compatible mating.

All objects have `part_id`, `source_url`, `evidence_level`, `description`, `attachment_parent`, `units` and `physical_validation`. Parts use `rack.*` stable names. PSU and power-shelf assembly origins are located at their front-bottom insertion datums; translate those assembly empties along negative Y to remove. Sheet parts, lids, supports, screws, contacts and guards are individually selectable. Perforations are actual through geometry. Modifiers keep edge radii editable.

## Dimensional contract

SI metres; +X right, +Y front to rear, +Z up. Rack floor centered X0/Y0; front faces negative Y. Values in the table are millimetres.

| Feature | Value | Authority/status |
|---|---:|---|
| Outside frame W×D×H | 600×1067×2210 | Facebook Open Rack Specification V2 rev12, §2.1 nominal envelope. The standard's 1048 mm target is not substituted. |
| Equipment bay | 538 | Open Rack Standard V2.0 §2.4, fig7; nominal clear opening |
| OpenU pitch | 48 | Standard §2.1 |
| Retention rectangle | 14×18 | Standard fig3; 24 mm vertical repetition |
| Screw bore | 5.5 | Standard figs3/4; actual holes in mesh |
| Deep latch distance | 789.6 | Standard §2.3 |
| Shelf bearing section | 20 wide,2 thick | Standard fig6 permits2.2 max thickness; selected2 mm |
| Four levelling feet; all casters swivel | Four each | FB specification §§2.32/2.4; detailed diameters reconstructed |
| Frame paint | Low-gloss RAL9005 | FB specification §2.7; PBR value approximation |
| Shelf body | 534.5×46.5×600 | Bel SPSTET4-07 rev004 p9, figures3–6 |
| Shelf overall depth | 859.5 | Bel p9, extended blades in figure5 |
| PSU casing W×H×D | 69×40.6×528.4 | TET4000-48-069RA BCD00883_B p15, exact dimensioned drawings |
| PSU connector | Amphenol FCI10127397-07H1420LF | TET p16; six power blades,3 AC blades,9 signal contacts |

The exact OU1 floor elevation0.180 m,41-OU occupancy, formed frame cross-sections not dimensioned in the accessible reference, wheel diameters, nut dimensions, sheet thicknesses outside specified interfaces, support fastener placement and bracket construction are reconstruction choices. They must not be presented as measured features of a particular Rittal rack.

## Power selection and evidence boundary

The early GE GP100 shelf candidate was rejected for integration because it is explicitly a shallow48V shelf. Its PDF and inspected images remain as rejected-candidate evidence. The final module uses Bel SPSTET4-07, whose ordering table explicitly states `+48V Deep Rack`. It is a real published six-module1OU shelf with an extended busbar output, two three-phase inlets, 54.5 V nominal output and an optional NAC slot. The authored configuration shows six TET4000-48-069RA exteriors; no unobserved rectifier circuit boards or transformer internals were fabricated.

Bel p9 conflicts with itself: its main dimensional row says534.5 mm width, while the parenthetical overall width and front-page summary say436.5 mm. The front drawing's six69 mm PSU bodies plus side bays is incompatible with a436.5 mm full shelf and consistent with534.5 mm. The module uses534.5 mm, preserving this explicit resolution. The shelf drawings are marked PRELIMINARY and contain no direct dimension arrows; this is not a substitute for measured vendor CAD.

The standard V2.0 and recovered V2.2 fig7 list only12V deep and48V shallow busbar datums. A2017 OCP workshop agenda explicitly proposed defining48V deep geometry. The present busbar uses the published48V cross-section topology (power/return, silver-plated copper, insulating supports and shield) shifted by the difference between deep and shallow latch distances. The default return front isY=.3972 m, or797.2 mm behind the equipment-front datum. **This location remains an integration inference.** Bel's shelf is designed for a deep48V rack; that does not prove its terminal mates with this reconstruction or with the acquired Zaius chassis.

Before declaring physical fidelity, compare the actual imported server48V connector to the bar faces, check PSU-shelf terminal attachment, and replace inferred geometry with exact rack/connector CAD if acquired. Do not manufacture or energize equipment from this visual asset.

## Sources and reconstruction method

See `research/rack-frame/PROVENANCE.md` and `source-manifest.json` for source URLs, licenses and SHA256. Actual acquisition, errors and Blender actions are in `logs/rack-frame-actions.jsonl`.

Research compared existing CAD before authoring. Official OCP rack/archive GitHub repositories were empty placeholders. Current rack wiki reference CAD is primarily ORv3; V1CAD was not silently repurposed asV2. The original files.opencompute.org links returned403. An official public OCP staging mirror supplied the exact PDFs but had an expired TLS certificate; this retrieval limitation is logged. Bel's current product page exposes a3D viewer, while its datasheet says casing STEP is available on request; no contact request was sent and no licensed STEP was acquired in this pass.

Consulted production references: craft-and-realism (choose production method, editable hero assets, neutral validation), historical-reconstruction (sources versus reconstruction), autonomy-and-handoffs (bounded ownership and resource scheduling), specialist-routing (hero-asset contract). All work remained in the owned module/source evidence paths. No shared scene, code outside this asset, git history or remote repository was changed.

## Validation and limits

The first standalone build succeeded in Blender5.2.1LTS without exception. Numeric validation and visual preview revisions are recorded separately in `research/rack-frame/validation.json` and this specialist's action log. The standalone file is a source checkpoint; integrated lighting, full-scene renders, device AR acceptance, robotic collision or dynamics, electrical safety, structural loading and service-procedure certification remain outside this module's proof.

Final standalone validation in Blender 5.3.0 Alpha (2026-09-08): **827 objects, 728 meshes, 53,194 base-mesh vertices**. Naming, metadata, 600 mm width, 1067 mm depth, 2210 mm top elevation, 48 mm OU pitch and insertion origins passed. All twelve perforated rail sheets are closed manifold meshes with zero non-manifold edges. The gray Workbench previews were visually inspected: `clay-front.png`, `clay-rear.png`, `rail-close.png`, `foot-close.png`, `power-close.png`, `power-rear-close.png`. The close-up review led to welded sheet topology and removal of internal tile walls, eliminating visible seams. Return folds extend to the base and crown flanges. These checks establish editable mesh construction and visual plausibility; source-server mating remains pending.
