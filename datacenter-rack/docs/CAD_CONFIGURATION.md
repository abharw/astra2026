# Barreleye EVT CAD configuration

`source/cad_configuration.py` selects a coherent no-GPU, 25GbE, dual-POWER9 assembly from the downloaded master STEP. The master contains overlapping supplier alternatives, old envelope exports and open/closed poses. The selection preserves every retained source transform. It is an authored selection from public hardware design data, not a verified factory configuration BOM.

## API

```python
from cad_configuration import build_configuration
configuration = build_configuration(index, source_report=None)
```

Both arguments accept parsed dictionaries or paths. `None` uses the pinned local files. The function uses no Blender APIs and changes no scene or input. It requires the STEP SHA-256 `823c119e2f7eebae3eda204590c4e6d54e0b990a43e4406987e476bbf41813a1` to prevent silently applying occurrence IDs to another revision.

- `keep_node_ids`: explicit retained occurrence IDs, including every ancestor. Do not recursively retain all descendants of these ancestors; only retain listed IDs.
- `keep_part_ids`: the same IDs with the existing `server.cad.` prefix.
- `excluded_nodes`: every excluded occurrence ID with a reason, including descendants of removed assemblies.
- `refdes_by_node`: 67 selected CAD part roots mapped to populated ODB designators. Descendants of a mapped assembly belong to that reference.
- `skip_refdes`: the 67 corresponding unique designators for `build_pcb_population`.
- `refdes_matches`: source MPN, CAD name, planar coordinate comparison, matching method and error. CAD part-family geometry is not asserted to be a manufacturer-exact body for every suffix.
- `lid_node_ids`: the top cover subtree `node-00608` plus its five screws, for a caller-controlled service view.
- `ram_slots`: 32 original `DDR4_DAISY_CHAIN` world matrices, bounds and matched socket designators. These provide placement references for a separately labelled DIMM reconstruction. The original daisy-chain geometry is excluded.
- `pcb_to_cad_matrix_m`: the verified original ODB-to-STEP transform.
- `selected_roots`, `cpu_heatsink_root_ids`, `vrm_heatsink_root_ids`, `validation`, `unverified`: compact integration and evidence metadata.

`python source/cad_configuration.py` prints validation. `--full` prints the full explicit manifest for a caller to save.

## Retained configuration

| System | Selection |
| --- | --- |
| Main chassis | `node-00001`, with the explicit descendant exclusions below |
| Motherboard substrate | `node-00773`, 330.2×563.88×3mm |
| DIMM sockets | `node-00814`–`node-00845`, one FCI 10140702 family at each of 32 source footprints; source BOM distinguishes blue/black variants |
| CPU/socket/loading mechanisms | `node-00982`, `node-01161`, including their source nested package/socket hardware, with duplicate unflexed springs removed |
| CPU cooling | Furukawa `HS855600-G2-A_ASM`, roots `node-03418` and `node-03505` |
| Converter-bank cooling | One source assembly at each of four positions: `node-02121`, `node-02124`, `node-02136`, `node-02139` |
| Network | `node-01807`, MCX4421A-ACAN; four mounting latches `node-01816`–`node-01819`; 25GbE panel `node-00723` |
| Storage | Assembled drawer `node-00276`, rail/backplane bracket `node-00594`, backplane `node-02307`, 24 source drive carrier assemblies, each with one closed lever |
| Fans | Six `01_6056-FAN-MODULE_POWER_ASM` roots; named Sunon PF6056 geometry, cage, leads, hardware and three selected flapper pieces per module |
| Fan power board / expander | Standalone board and connector objects, with old whole-board EMP overlays and explicit duplicate headers removed |
| Rear power interface | Named `2204793-2CVM_1208` CAD option `node-09930`; factory option BOM has not been identified |
| Remaining packages | Populated ODB/BOM generator supplies motherboard devices not retained as CAD matches |

NVIDIA identifies [MCX4421A-ACAN as a dual-port 25GbE SFP28 OCP adapter with PCIe 3.0 x8](https://network.nvidia.com/related-docs/firmware/ConnectX4Lx-FW-14_25_1020-release_notes.pdf). This supports the interface/panel choice. No other overlapping OCP NIC is retained. No GPU, generic PCIe clearance card, or external VGA cable is installed in the default selection.

## Exclusion evidence

The master has two HDD drawer subtrees with the same geometry separated by exactly 455mm along the drawer axis. `node-00435` and its matching rail `node-00601` are the open/exploded alternative; selecting the assembled pair reduces maximum source Z from approximately +495mm to +40mm. The remaining +40mm includes the original drawer handle. No part was translated to obtain this result.

Within each of 24 carriers, `2_FOXCONN-LEVER_AGLAIA` occurs both closed and rotated 45 degrees at the same hinge. The rotated lever is excluded. The small dummy tray at the intentionally empty bay remains; the overlapping taller dummy option `node-00422` is removed.

Each fan module contains named `5_FAN_SUNON_PF6056` and a second `FAN-6056-POWER9` body at the same placement. The named source model includes its leads; the second body is excluded. Two old `2_FLAPPER_POWER9` shapes overlap the retained three-piece `2_FAN-FLAPPER_SH` set. Module-local stationary `456260008` instances are removed in favor of the fixed root-level counterparts.

The motherboard contains several DIMM socket families in the same 32 positions, plus dated EMP exports containing full board geometry. Only the FCI 10140702 family and standalone substrate are retained. Older PCIe connector models use different supplier part numbers from the populated EVT BOM, so those CAD alternatives are excluded and the ODB generator supplies the actual BOM footprints. Other alternate/mismatched connectors are handled the same way. This avoids silently assigning an obsolete CAD model the identity of a newer BOM part.

The separate CPU mechanisms contain both flexed and unflexed spring shapes with overlapping bounds. The selected loaded/flexed geometry remains; nodes `01147`, `01154`, `01326`, `01333` are excluded as alternate poses. All alternative CPU heatsinks, duplicated backplates and stray/off-board thermal options are excluded. Four converter-bank cooling assemblies remain at distinct source positions; their near-duplicate and older counterparts are excluded.

The source calls its RAM geometry `DDR4_DAISY_CHAIN` and does not establish a DIMM module MPN in the inspected motherboard BOM. A validation/clearance role is a naming inference, not a confirmed source fact. Accordingly it is excluded from installed-memory claims. All 32 slot transforms are retained as placement references; source socket MPNs are established independently.

## Coordinate proof and limits

For ODB coordinates in meters, the source CAD coordinates are:

```
cad_x = odb_x - 0.228
cad_y = odb_z + 0.0105
cad_z = -odb_y - 0.00313
```

The substrate bounds agree with 3mm thickness, and the two source CPU assembly datums match U1/U10. DIMM mapping compares CAD planar bounds centers with transformed ODB package envelopes, accounting for the source footprint origin being offset from its body center. All 32 socket matches are below 0.2mm. Across all 67 retained CAD/ODB references, the largest planar center difference is 0.335mm. No reference is duplicated, every skipped reference is populated, and all 32 RAM slot mappings are one-to-one.

After selection and spring-pose cleanup: 2,406 retained nodes, 2,022 mesh occurrences and 7,534 excluded nodes. No retained leaf occurrences share both the exact definition and world transform. Selected source bounds are approximately X[-275.71,272.88], Y[-0.40,92.30], Z[-888.77,40.04]mm. AABB agreement proves registration only; it does not prove every surface fit, spring load, pin position or cable routing. The integrated Blender scene still requires visual and interference review.

The retained named rear connector is a transparent configuration choice: inspected evidence did not resolve it against the overlapping opaque `0002413426` model. The latter is excluded and preserved in the original variant library. Neither is presented as a confirmed factory BOM choice.

Sources are the public [OCP Zaius/Barreleye G2 repository](https://github.com/opencomputeproject/zaius-barreleye-g2), pinned local EVT STEP and ODB/BOM payloads. Source revision, license and hashes remain in the acquisition register; action and validation evidence for this selection is appended to `logs/pcb-population-actions.jsonl`.
