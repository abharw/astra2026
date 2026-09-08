# OCP rack/server acquisition findings

Research owner: rack_openhardware_research. Retrieved 2026-09-08. Bounded research/acquisition only; no final hardware selection, modeling, CAD import, or geometric acceptance performed here.

## Strongest available candidate: Zaius / Barreleye G2

The official [OCP repository](https://github.com/opencomputeproject/zaius-barreleye-g2) provides a much deeper source set than the Tioga Pass files presently accessible from the legacy OCP host. It covers the IBM POWER9 platform, not an Intel server. Repository tree inspected at `125c5c264c26f97550da8c19539becb71cf7dc6c`. Originals and derivative inspections are preserved separately. All byte sizes below are actual acquired file sizes; Git LFS downloads were checked against pointer size/hash.

### Coherent EVT handoff — use this revision for the initial full STEP reconstruction

At the director's request, the matching published EVT3 electrical package was subsequently acquired. Preserve this as a separate historical edition from PVT. The full STEP is dated 2017-03-10; the matching repository EVT motherboard files are dated 2016-12-26 with BOM update2017-01-06. This is evidence of the same development phase, not proof that every file was released as one manufacturing configuration. Revision/fit comparison remains an integration gate.

| Additional acquired source under `originals/zaius-barreleye-g2/` | Bytes | Actual contents |
|---|---:|---|
| `HW/EE/GBR/EVT/MB/Zaius-EVT3-LAYOUT-MB-GBR-X02-20161226-Final.zip` | 159648997 | Outer mechanical PDF + stackup PDF, nested FAB/MDF, actual Gerber/NC/assembly/placement data. |
| `HW/EE/GBR/EVT/MB/Zaius-EVT3-LAYOUT-MB-ODB-X02-20161226-Final.zip` | 63561829 | Outer PDFs and `Zaius-EVT3-MB_V6.tgz` ODB++ archive,897 entries. |
| `HW/EE/BRD/EVT/Zaius-EVT3-LAYOUT-MB-BRD-X02-20161226-Final.zip` | 80103144 | Native Cadence board. |
| `HW/EE/SCH/EVT/MB.zip` | 14201605 | OrCAD DSN and readable 7542681-byte schematic PDF,252 sheets. |
| `HW/EE/BoM/EVT/ZAIUS-MB-EVT3-HW-EBOM-X00_20161228-add_2nd_source_X15-20170106-Final.xls` | 558427 | Actual ZIP/XML XLSX container despite `.xls` filename; PWA BOM plus DEPOP/alternates. |
| `HW/thermal/EVT/G2-CPU HSK-Furukawa-HS855600.pdf` | 48497 | CPU heatsink drawing. |
| `HW/thermal/EVT/Zaius-VTM-1-HS855360-C.pdf` | 84889 | VTM heatsink drawing. |
| `HW/thermal/EVT/Zaius-VTM-2-HS855370-C.pdf` | 48027 | VTM heatsink drawing. |

**Use `inspection/evt-odb-placement-bom.json` for board reconstruction metadata.** It contains7867 unique ODB reference designators, placement, EDA height, raw ODB/PCP rotation conventions, BOM candidates with sheet/row locators, and explicit population state:6663 PWA-BOM-listed,1006 DEPOP-listed,198 unresolved. Unresolved entries include holes/fiducials/testpoints and require classification; the count is not a claim of7867 installed chips. The PCP fixed-width report clips18 long names (including several capacitors into duplicates); ODB retains the full unique names. All centers were matched by name or documented clipped-name plus position, with maximum difference0.0016mm. These are independent source-field consistency checks, not a physical measurement.

`inspection/evt-odb-package-bounds.json` contains198 package records copied from ODB EDA data, including original records and numeric fields. EDA bounds and `.comp_height` do not by themselves specify exact molded geometry, markings, lead profile, or solder shape. Preserve that distinction. Both ODB and PCP angle/mirror values are retained because their conventions differ.

Other EVT derivatives: `evt-component-centers.json` (raw PCP with clipped identifiers), `evt-bom-primary-items.json` (441 located PWA rows), `evt-bom-depop-refdes.json` (1006 refs), `EVT-BOM-sheet*.json` (raw worksheet cells), `evt-odb-components.json`, `evt-odb-summary.json`. Extracted schematic/assembly/outline PDFs, DXF, reports and selected decompressed ODB data reside in `inspection/extracted/zaius-EVT/`. `scripts/inspect_evt_odb.py` records the extraction and unit crosscheck. ODB coordinates are verified against PCP with a25.4 conversion factor; do not infer a matching angle convention from that coordinate result.

EVT identity examples, superseding PVT examples when modeling EVT:

- U1/U10 sockets: Foxconn `PE38993-51BC0-1H`, PWA BOM row702.
- U5 sequencer: Texas Instruments `UCD90160RGCR-C09`, row610.
- U13 PHY: Broadcom `BCM54612EB1KMLG`, row613.
- U14 BMC: ASPEED `AST2500A2-GP`, row614; both description and MPN agree in EVT.
- LOM1: Broadcom `BCM5719A1KFBG`, row148.
- Blue DIMM sockets: FCI `10140702-0302K11LF`,16, row669. Black DIMM sockets: FCI `10140702-0301K11LF`,16, row670. Actual installed RDIMM-module SKU still requires selection/evidence.

Full EVT STEP structure:1431 PRODUCT definitions,1924 MANIFOLD_SOLID_BREP entities, SHA256 `823c119e2f7eebae3eda204590c4e6d54e0b990a43e4406987e476bbf41813a1`. Mixed millimeter/centimeter representation contexts occur. A proper STEP importer must apply each context/transformation; global scaling of raw vertex coordinates would be unsafe. No import performed by this specialist.

### Preserved PVT source set and other initial downloads

| Acquired original, relative to `originals/zaius-barreleye-g2/` | Bytes | Actual contents and use |
|---|---:|---|
| `HW/ME/Barreleye G2 3D for PVT-20180410.7z` | 412741617 | 1248 Creo `.prt.1` and 217 `.asm.1` files, 2.31 GB uncompressed. Top assembly `00_server-2ou-tla-sku3_power9.asm.1`. No neutral CAD format. Best native PVT detail, requires a proven Creo conversion route. |
| `HW/ME/EVT/Barreleye G2 3D STP-20170310-detailed.zip` | 171222411 | One STEP assembly `00_server-2ou-tla-sku3_power9_asm.stp`, 1010529339 bytes unpacked. Direct neutral-CAD candidate, explicitly EVT 2017-03-10, NOT the later PVT configuration. |
| `HW/ME/Zaius_tray_3D_PVT.zip` | 15382590 | One STEP `zaius_tray_3d_20180410.stp`, 89343000 bytes; 82 PRODUCT definitions and 157 MANIFOLD_SOLID_BREP entities. Alternative compact Zaius sled, not full Barreleye chassis. |
| `HW/EE/BRD/Zaius-PVT-LAYOUT-MB-BRD-X04-20171215-Final.zip` | 72806548 | Cadence `.brd`, 249042848 bytes. Native PCB layout source; import/conversion not tested. |
| `HW/EE/SCH/ZAIUS-MB-PVT-HW-SCH-X04-20180124-FINAL.zip` | 8757378 | OrCAD `.DSN`, 61304832 bytes. Native schematic; no schematic PDF in this particular archive. |
| `HW/EE/GBR/Zaius-PVT-LAYOUT-MB-GBR-X04-20171215-Final.zip` | 161980776 | Three outer PDFs, manufacturing `.doc`, nested FAB/MDF ZIPs. FAB: top/bottom assembly `.DXF` and `.PDF`, outline PDF, panel PDF. MDF: 36 `.ART` layers, NC drilling, `.ipc`, `.net`, `.cad`, `.pcp`, `.ptx` and other manufacturing outputs. |
| `HW/EE/BoM/ZAIUS-MB-PVT-X04-BOM_X31_20180131_Final.xls.xlsx` | 652725 | Actual XLSX workbook; PWA BOM, assembly BOM, alternates, DEPOP and historical change sheets. |
| `specs/Barreleye G2 - Zaius OCP HW Spec V0.9.0 06102018.pdf` | 8695807 | Specification with system architecture, dimensions, mechanical views, power path, connector pinouts, standalone Lunch Box, and explicit remaining development gaps. |

### Immediately available import/reference files

- Full neutral CAD: `inspection/extracted/barreleye-EVT-detailed/00_server-2ou-tla-sku3_power9_asm.stp`. About 1 GB ASCII STEP. Its historical revision must remain visible. Text structure statistics are saved in `inspection/Barreleye-G2-EVT-summary.json`; these are not counts of installed physical objects or proof of a successful import.
- PVT component centers: `inspection/pvt-component-centers.json`, decoded from the actual top/bottom `.pcp` reports. 7772 positions: 4481 top, 3291 bottom. Includes refdes, device text, package, x/y in both mm and mils, angle, mirror flag, and source. Validate origin/axis against outline and CAD before applying. Bottom-side mirroring is not resolved simply by negating X.
- Primary located PWA BOM rows: `inspection/pvt-bom-primary-items.json` (437 rows). This is a convenient partial derivative, not replacement for the workbook; alternative rows lacking locations are not folded into these records.
- Depopulation references: `inspection/pvt-bom-depop-refdes.json` (1206 unique entries from the DEPOP sheet). Empty footprint locations are not installed chips. Preserve population decisions and revision provenance.
- Raw PCB placement, top/bottom DXF/PDF, outline, and design PDFs: `inspection/extracted/zaius-gerber/`.
- All archive inventories under `inspection/*listing.txt`; STEP PRODUCT names under `inspection/*products.txt`.

### Concrete component identity examples

| Refdes | Actual BOM manufacturer/part | Role / caveat |
|---|---|---|
| U1, U10 | Foxconn `PE38993-51BC1-1H` | LGA3899 POWER9 CPU sockets; CPU die geometry is not provided by a socket model. |
| U5 | Texas Instruments `UCD90160RGCR-C13` | Power sequencing controller. |
| U13 | Broadcom `BCM54612EB1KMLG` | Management Ethernet PHY. |
| U14 | ASPEED `AST2520A2-GP` | BOM description says AST2500A2 while manufacturer-part cell says AST2520A2-GP. Preserve this explicit source conflict. |
| C1 and other listed positions | Murata `GRM1555C1H470J` | Example part in the DEPOP sheet; do not blindly install every center-report location. |

The manufacturing files support actual PCB layer and component placement work. They do not supply every package's exact molded body, color, markings, solder profile, or silicon mask layout. PCB `.ART` graphics need interpretation and alignment; they are not Blender meshes. The mechanical PVT/PCB PVT set and the older EVT full STEP must not be silently merged as one exact production configuration.

## Rack, power, and dimensions

The downloaded specification states 48-volt Open Rack v2 (section 5, printed p13), not ordinary 19-inch EIA racks and not ORv3. The server-specific rack and power shelf are explicitly still under development in section 13.3, printed p55. A separately sourced and verified compatible rack/power shelf is still needed.

- Section 13.1.1, p44: Barreleye G2 2OU chassis prose dimensions **537 × 801 × 92.3 mm**.
- Section 13.1.5, p48: motherboard **564 × 330 mm**, 2 POWER9 CPUs and 32 DIMM sockets.
- Section 13.1.10, p53: HDD tray **501 × 151.9 × 88.9 mm**.
- Section 13.2, p54: compact Zaius sled approximately **340 × 610 × 66 mm**, four rear 60-mm fans; associated 1.5OU shelf **537 × 660 × 72 mm**, horizontal rear 48-V busbar and accessory space.
- **Source conflict:** visually inspected p45's GPU-SKU top-view labels 816 mm main extent plus 88.97 mm rear fan extent, and 499.8 × 152.2 mm drive tray, differing from prose. The figure also labels 4056 fans while the PVT native archive includes 6056 fan assembly filenames. Preserve SKU/revision distinctions and measure chosen CAD; do not overwrite geometry to force every printed dimension.
- Barreleye G2 front drive tray houses up to 24 SAS or 20 NVMe 2.5-inch drives; rear carries six hot-pluggable fan modules and one 48-V busbar clip (pp45–47).
- Four major board assemblies: Zaius motherboard, tri-mode expander, fan/power distribution board, and tri-mode HDD backplane. Cables/chain appear in p45; exact cable harness needs selected revision inspection.
- Section 14, pp56–60: rear 48-V busbar clip feeds fan/power distribution board; two 48-to-12-V converter bricks power fans, expander, backplane and GPU. Motherboard power is a latching four-pin vertical Molex MiniFit Sr connector, specified 40 A at 48 V DC. For compact Zaius sled, its cable connects directly to rear busbar connector instead.
- Section 15 describes a separate standalone 48-V Lunch Box. It is not evidence of a completed rack power shelf.

Visual inspection performed: specification page45 top-view diagram, saved as `inspection/barreleye-spec-topview.png`. Other reported dimensions/power passages were read from extracted text. Full multi-view image/CAD review remains required.

## Rights evidence

`README.md` and `license.md` in the downloaded official repository explicitly state **OCPHL-P 1.0**, with exceptions for separately listed items. The spec's printed pp2–3 repeats that license and lists merely referenced technologies, including POWER9, ASPEED, OpenCAPI/NVLink, named controllers/connectors, and firmware. Therefore the server design license does not disclose or license proprietary internal silicon implementation. Retain `license.md`, `notice.md`, spec notices and attribution with derived distributions. `notice.md` includes IBM notices and conditions for retaining notices with derivatives. Do not represent public CAD acquisition as engineering certification or rights to third-party logos.

## Other acquired candidates

### Facebook Intel v1 / Freedom triplet

Official [facebookarchive/opencompute](https://github.com/facebookarchive/opencompute/tree/master/archive), tree `186be0f5d14d25791d9f00321a9711c052b033b6`.

Downloaded to `originals/opencompute/archive/`: Intel motherboard CAD ZIP (21474241 bytes), chassis mechanical ZIP (2593184), rack triplet mechanical ZIP (18444095), motherboard spec PDF, chassis/triplet spec PDF. Each CAD ZIP contains STEP + SLDASM and an explicit **CC BY 3.0** `License.html` inside the archive; preserved license extracts under `inspection/`. The STEP content includes named connectors, CPU fasteners/socket structures, chassis rivets/standoffs and rack parts. Motherboard has 113 PRODUCT definitions/80 solid B-reps; chassis20/17; triplet94/79. These are distinct geometric definitions, not occurrence counts. This provides a coherent older mechanical fallback but no equivalent detailed electrical layout/BOM set was acquired.

### Microsoft Project Olympus

Official [OCP Project Olympus](https://github.com/opencomputeproject/Project_Olympus), tree `810bc17f6ce93e3d46af24cacd205a1ad783b9ee`. Downloaded `originals/Project_Olympus/HW/ProjectOlympusComputeServer20170410.7z` (20478857 bytes), containing `00_olympus_1u_asm.stp` (206568206 bytes), 321 PRODUCT definitions/265 solid B-reps. Extracted to `inspection/extracted/`. HW LICENSE states OWFa1.0. README warns mechanical/spec changes may be out of sync. Electrical collateral exists in old wiki links but was not acquired; weaker overall evidence set here than Zaius.

### Prioritized but inaccessible: Tioga Pass / Wiwynn SV7220G3

Official [product page](https://www.opencompute.org/products/229/wiwynn-tioga-pass-advanced-2u-ocp-server-up-to-768gb-12-dimm-slots-4-ssds-for-io-performance) identifies SV7220G3 and contribution S0143. Coreboot's official [Tioga Pass documentation](https://doc.coreboot.org/mainboard/ocp/tiogapass.html) identifies open electrical collateral at `https://files.opencompute.org/oc/public.php?service=files&t=6fc3033e64fb029b0f84be5a8faf47e8`. This URL returned403. Legacy Intel v2 mechanical links and shelf CAD links also returned403. The current contribution page returned403 to terminal clients; a staging hostname had an expired certificate (verification was not disabled). No Tioga Pass design ZIP was downloaded; do not call it locally available.

## Process and handoff

`source-register.jsonl` records successful source URLs, file paths, sizes and SHA-256 hashes. `actions.jsonl` records observable tools/methods/outcomes. Early events are explicitly retrospective, with available filesystem timestamps; no fabricated start time. `scripts/acquire.py` records exact future download argv/start/outcome and verifies expected size/hash. Research used web tools and terminal/Python/archive tools; no GUI browser automation, Blender operation or generation API was used by this specialist. Exact authoring-model identity was not exposed in runtime metadata.

Next gate: CAD import and source-matched visual inspection, deciding whether to convert PVT Creo or use the explicitly older full EVT STEP. Then resolve matching rack/power shelf and configuration. CAD import, current assembled geometry, photorealism, AR, physical fit, and electrical/robotics behavior remain unverified.
