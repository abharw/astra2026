# From published hardware to an inspectable rack

The brief was to pre-model a detailed server rack for human learning and future AR/robotics experiments: rack, servers, removable parts, chips and editable wires. The production workflow uses Codex to research, coordinate the work, write Blender/Python tools and inspect the actual results. It does not use a generated image as a substitute for the hardware geometry.

## 1. Choose hardware with evidence at several scales

We first compared conventional vendor service manuals with Open Compute hardware. The decisive source was the public Zaius / Barreleye G2 design repository: it supplies a detailed neutral STEP mechanical assembly, the motherboard schematic, BOM, ODB++ manufacturing data and Gerber layers. That makes it possible to move from a real chassis assembly down to named board components without inventing their placement.

The chosen revision is the 2017 EVT mechanical assembly with the matching EVT3 electrical sources. Later PVT hardware is kept distinct. The rack frame is reconstructed from Open Rack V2 drawings, with a separately documented Bel 48 V power shelf. Combining those sources does not itself prove mechanical or electrical interoperability.

## 2. Keep CAD structure instead of flattening it

OpenCascade imports the STEP assembly and resolves its units and transforms. A custom tessellator preserves reusable part definitions and individual assembly occurrences. Blender receives named objects, parent relationships, local transforms, source hashes and repeated mesh instances. A small known-dimension solid checked the unit conversion before the full import.

The full source contains 9,940 assembly occurrences and mutually exclusive design alternatives. Loading them all produces overlapping GPU trays, heatsinks, connector alternatives and both open and closed drawer positions. `source/cad_configuration.py` explicitly selects one assembled configuration, retaining a reason for each excluded branch. The complete source derivative remains a separate research artifact.

Missing surface triangles are investigated against the original boundary-representation faces. Zero-area construction remnants, invalid source surfaces and repairable tessellation failures are reported separately. A successful import is not treated as evidence that every surface is intact.

## 3. Populate the motherboard from fabrication data

The source BOM identifies 6,663 populated reference designators. The ODB++ data provides package outlines, terminal outlines, positions, rotations and nominal height envelopes. The script builds an object for each populated part and records the manufacturer, part number, refdes, package and source. It excludes depopulated and unresolved placements from physical population claims.

Where the mechanical CAD already contains a matching detailed socket or connector, the population generator skips that refdes. The source board dimensions and several independently matched component centers establish the fabrication-to-CAD transform. Real Gerber copper, mask openings and silkscreen are then registered to the board surface. The red OSP substrate comes from the board BOM; the rendered reflectance is an authored material approximation.

The host memory modules are explicitly class analogues based on a public DDR4 RDIMM drawing. They do not invent an installed inventory, serial number or unprovided DRAM chip identity. Explanatory processor internals must remain distinct from manufacturer mechanical CAD and actual transistor layout.

## 4. Build for inspection

The Blender file separates the detailed server, removable cover, rack structure, power shelf, cable harness and presentation lighting. Rack servers reuse a collection to avoid duplicating the detailed geometry. Individual master parts retain editable meshes and source identity. Cable paths are editable curves with endpoint metadata and an explicit routing-evidence status.

The Rack Lab sidebar searches metadata, frames an assembly, selects a parent, isolates parts, restores prior visibility, and explodes/restores transforms. Its persistence checks include saving, reopening and renaming objects. Actual clicks in the final Blender model are a separate acceptance step recorded in the journal.

The management port research illustrates why source reading matters: connector shape alone does not establish function. Several SAS-style motherboard connectors are NVLink interfaces, not storage ports. Similarly, BMC management electronics are not evidence of a facility SCADA cabinet.

## 5. Render and verify the actual asset

Blender renders the real geometry with separate materials, studio lighting and cameras. The work includes open-server, motherboard and rack views, followed by inspection of the resulting images. Renderer completion, geometric checks, usable selection and actual AR performance are different forms of evidence. The validation receipt identifies which were performed.

## What “computer use” means in these logs

| Activity | Actual mechanism | Evidence |
|---|---|---|
| Find public drawings and documentation | Web search/open tools and HTTP downloads | Source registers and acquisition logs |
| Read schematics/BOM/ODB/Gerber | Python, PDF extraction, page images, direct image inspection | Parsed source data, scripts, hashes and inspection receipts |
| Preserve mechanical geometry | OpenCascade STEP/XCAF and NumPy | Conversion script, assembly index and diagnostics |
| Author the asset | Blender Python through Blender CLI | Reproducible source scripts and command records |
| Inspect the native application | Codex computer-use tool, Blender window state and screenshots | Explicit computer-use events; no claim that CLI work was mouse work |
| Coordinate bounded specialists | Codex subagents with separate owned files | Specialist logs and handoff artifacts |

The user calls this GPT-Astro/Astra. The existing application documents `gpt-6-astra` for its own generation calls. This asset-authoring session is evidenced as Codex-driven work; an exact authoring-model identifier was not independently exposed by runtime metadata. We do not manufacture an API trace or claim that a Blender calculation was a model call.

## Audit trail and limits

`logs/actions.jsonl` records observable root operations; specialist logs record their owned work. Command records include exact argument vectors, working directories, completion status and hashes of local stdout/stderr. The first entries are marked retrospective because structured logging started after initial discovery. This is a production action record, not an uninterrupted screen recording. It excludes credentials, private reasoning and unrelated activity.

The result is a source-based visual training asset. It is not a validated digital twin, an electrically simulated rack, a torque/force-accurate robot environment, or a claim to have reconstructed proprietary transistor layouts. The asset's metadata keeps those boundaries inspectable alongside the geometry.
