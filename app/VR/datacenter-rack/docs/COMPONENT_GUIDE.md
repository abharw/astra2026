# Component guide — Zaius / Barreleye G2 EVT3

This library is an inspectable explanation and modeling constraint set for the selected Open Compute POWER9 server. The exact motherboard population comes from the EVT3 BOM and ODB manufacturing export. The later platform specification supplies architectural context; it does not silently upgrade the selected EVT mechanical assembly to PVT.

## Use the library

`source/component-library.json` contains manufacturer/MPN records in `components` and occurrence records in `instances_by_refdes`. Select a refdes, resolve its `component_keys`, and show the identity, function, sources and uncertainties. Keys retain the original category and exact BOM MPN; `semantic_type` provides the refined role. A key is an identity, not a serial number.

Every BOM record includes its workbook sheet and one-based row. Each occurrence preserves the true ODB refdes, source coordinate, side, rotation, package index, EDA height envelope and population status. `height_eda_envelope_mm` is a design envelope, not a measurement of a manufactured object. Bottom-side coordinates require an explicitly validated board-to-scene transform. Record that transform separately. Do not infer it by negating one axis.

J110 lacks its original EDA height. Its optional `geometry_candidate` records10.100056mm inherited from35 identical-MPN/same-footprint siblings, explicitly as a supported reconstruction; the original height remains null. The custom Samtec print was not acquired.

An occurrence can have zero or multiple candidate identities. Preserve `listed_in_depop` and `population_status`; do not create a chip at every manufacturing-file coordinate. The library explains the BOM, not a photographed specimen. The first release has 440 unique BOM identity records plus nine explicitly labeled context records, and 7,867 placement occurrences.

Rebuild with `python3 research/components/build_library.py`. The builder reads the source specialist's files in `../research/ocp-candidates`; the source hashes are embedded in the output. It performs no scene edit, Git operation or download. Source pages rendered for study are in `research/components/pages`; downloaded references have SHA-256 and rights notes in `research/components/source-register.jsonl`.

## Hardware identity and hierarchy

| Assembly or part | Documented identity | Training relationship and evidence |
|---|---|---|
| Rack integration | 48V Open Rack v2 context | Separate rack source controls geometry. Neither a 19-inch rack nor an ORv3 shelf is implied by the server model. |
| Server | Barreleye G2 EVT mechanical assembly | Chassis carries the motherboard, drive system, fan/power board and cabling. Native CAD owns shape and attachment positions. |
| Motherboard | GCE `0101EJD00-000-G`, EVT3-X02 | BOM row5: red OSP board, 22 layers. Use matching fabrication layers for actual copper/silkscreen. |
| Processor module | IBM POWER9 **LaGrange** | Platform family documented; exact orderable CPU SKU, stepping and enabled cores unspecified. |
| CPU sockets | Foxconn `PE38993-51BC0-1H`, U1/U10 | BOM row702. These are LGA3899 sockets, not two CPU part numbers. |
| Host DIMM sockets | FCI `10140702-0302K11LF` blue / `10140702-0301K11LF` black | BOM rows669/670 give exact 16+16 socket populations. Host DIMM module SKU remains unspecified. |
| BMC | ASPEED `AST2500A2-GP`, U14 | BOM row614, schematic sheets141–147. Separate management computer, not a POWER9 core. |
| BMC memory | Micron `MT40A512M16JY-083E:B`, U17 | BOM row616, sheet142: soldered DDR4 for the BMC. It is not host memory. |
| Management PHY | Broadcom `BCM54612EB1KMLG`, U13 | BOM row613, sheet140. Converts BMC RGMII traffic to the copper Ethernet link. |
| Host LAN controller | Broadcom `BCM5719A1KFBG`, LOM1 | BOM row148, sheets135–140. Host PCIe network controller with NC-SI capability. |
| Network jack | TRP `1840855-5`, LAN1 | BOM row693, sheet140: bottom PortA is management PHY; top PortB is BCM5719. |
| Power sequencer | TI `UCD90160RGCR-C09`, U5 | BOM row610, sheet168. Monitors and sequences supply rails. |
| Regulation control | Intersil `ISL68137IRAZ-EVT3` | BOM row264; controller supports feedback/PWM/PMBus/AVSBus. Keep the board suffix, which differs from the generic datasheet ordering code. |
| Current multiplier | Vicor `VTM48MP012T130AA0` | BOM row266 at PBAU4/PAAU4/PBAU6/PAAU6; detailed circuits include sheets181–183. |
| Input connector | Molex `42819-4233`, J27 | BOM row685, sheet250. Four mating circuits in a single row; see contradiction below. |

Most remaining BOM records retain a category-level explanation. A capacitor may decouple, filter or shape timing depending on its actual nets. The library deliberately does not invent a unique electrical role for every passive just because its refdes and MPN are known.

## Detail that the evidence supports

| Subject | Constraint | Inspection / limit |
|---|---|---|
| POWER9 package | 68.5 × 68.5mm; FC-PLGA; 3,899 lands; 1.016mm hexagonal land pitch; 7-2-7 organic substrate construction | IBM LaGrange datasheet v1.7 p77 visually inspected. Socket external envelope comes from CAD, not these module dimensions. |
| POWER9 die explanation | Labeled core/cache/interconnect regions and execution-slice architecture | IBM Hot Chips2016 pp4,5,7 inspected. Family-level illustrations support explanatory regions. No physical die scale, exact package orientation or transistor-mask layout is established. |
| UCD90160 | 9 × 9mm nominal; ≤1mm body height; 64 perimeter terminals at0.5mm pitch | TI datasheet p52 package drawing visually inspected. Exposed thermal pad is a bottom feature. |
| ISL68137 | 6 × 6mm nominal; ≤1mm height; QFN48 at0.4mm pitch | Renesas/Intersil datasheet p54 visually inspected. Model the leadless outline rather than long gull-wing pins. |
| Vicor VTM | Manufacturer product page lists13.49 × 22.5 × 4.5mm body; public brief illustrates18 terminals | PDF pp1–2 inspected. Dimensions are webpage data, not a toleranced outline. Internal resonant components remain explanatory. |
| Host RDIMM example | Kingston KVR24R17D4/32:133.35 × 31.25mm PCB; key centered72.25mm from illustrated left edge, width1.50±0.10mm | Kingston p2 inspected. This is an expressly labeled supported-class analogue, not proof of the selected server's installed module. |
| CPU heatsink | Furukawa HS855600-A:100 × 91mm base, maximum68.2mm height,85mm fin-stack width,70mm square contact area | EVT Furukawa drawing p1 inspected; C1100 copper block/fin assembly and ADC10 base listed. |
| VTM heatsinks | HS855360-C:80 × 40 × 25mm; HS855370-C:80 × 57.3 × 32.6mm | Both EVT drawings p1 inspected;3mm base, separate pads and spring pushpins. Match their footprints before placement. |
| Actual board locations | 7,867 ODB component origins with side, rotation and EDA heights | Source specialist validated centers. Integrator still must validate board axes against the native mechanical CAD. |

For the RDIMM example, use both front and back diagrams. The asymmetric edge key and end notches are more important than invented label artwork. The example has36 DRAM packages; its datasheet does not identify the exact DRAM MPNs. Do not apply U17's Micron x16 chip identity to those host-memory packages.

For package cutaways, keep actual external geometry selectable separately from explanatory internal blocks. Labels such as “core,” “cache,” “DRAM bank,” “ADC,” and “power conversion stage” describe functions. A block diagram neither supplies a transistor netlist nor proves actual hidden placement. A viewer entering the cutaway should see its explanatory status.

## Power and management connections

The EVT power map on schematic sheet4 is useful for teaching the path from48V input through board conversion to CPU, memory and auxiliary rails. Its map includes older controller/part shorthand that differs from detailed BOM rows. Use the final matching BOM for identity and the detailed rail sheets for precise electrical relationships; do not substitute a generic server VRM arrangement for the documented Vicor stages.

J27's BOM shorthand says2×4/DIP8. The actual Molex part and schematic sheet250 show **four mating circuits in one row**, with paired board terminals. The manufacturer lists10mm pitch and a40.9mm body length. It should not look like an eight-cavity GPU power connector. The schematic shows48V, an enable signal and chassis/ground returns; exact cable pin routing must remain tied to that sheet. The drawing download timed out during research, so manufacturer dimensions remain a remote-primary reference until a local drawing is acquired.

The BMC, U17 memory, firmware flash and Ethernet PHY form a management subsystem alongside the host. Dedicated management networking can operate while host software is unavailable if the required standby power and management path are working. No live status or firmware was read during this task.

The later specification distinguishes two sensor arrangements. Compact Zaius uses external1-wire header sensors. **Barreleye G2** specifies TMP75AIDR devices over SMBus at inlet, fan board and HDD board (§9.9.2, actual p27). Do not turn the compact-sled arrangement into Barreleye geometry. Those sensor part positions have not been independently established in the motherboard PWA BOM derivative. The specification's fan-board address0x72 is retained as a textual claim; check the actual bus/multiplexer circuit before using it as a7-bit sensor address.

BMC refers to the server's management electronics. DCIM refers to software that may aggregate asset/facility/IT information. SCADA refers to supervisory control of facility/industrial processes where such a system exists. This source set does not identify a facility PLC or SCADA cabinet. None should be invented inside the server.

## Source and revision limits

- The platform specification's table of contents has stale page references. Actual PDF/footer pages used here: memory18, BMC overview23, power/thermal monitoring26, Barreleye sensors27. Prefer actual sheet/page locators over the contents page.
- Do not substitute PVT's socket revision or AST2520-related BOM conflict into EVT3. Keep design revision in displayed metadata.
- The public LaGrange datasheet p16 references a separate thermal/mechanical guide. That full guide was not acquired; therefore lid profile, exact substrate thickness, package marking template and die-to-package orientation are not claimed from it.
- Exact host CPU/DIMM/storage orderable SKUs, serials, lot codes and live health state were not supplied. Context examples are not physical inventory.
- Public manufacturer PDFs were retained for research with their notices. The OCP hardware license is not a license to redistribute proprietary chip internals or third-party artwork. The register separates public reference availability from redistribution rights.

## Observable work and acceptance

This specialist used web research, terminal/Python parsing and HTTPS acquisition, Poppler PDF extraction/rendering, and image viewing. No Blender, native-GUI operation, image generation, model API request, Git action or heavy rendering was performed by this specialist. The exact authoring-model identifier was not exposed by runtime metadata. Events and corrections are in `logs/component-research-actions.jsonl`.

Validation checks JSON referential integrity, matching source paths/hashes, source-supported landmark identities and explicit population state. It does not establish Blender appearance, physical fit, electrical behavior, live BMC operation, AR placement or robotics dynamics. Those are separate integration gates.
