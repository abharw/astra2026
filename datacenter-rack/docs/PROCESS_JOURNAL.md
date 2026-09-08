# Rack production journal

## Record scope

This journal records observable actions and engineering/art decisions. It does not contain private model reasoning, credentials, unrelated computer activity or conversations. Machine-readable events are in `../logs/actions.jsonl`; source acquisition registers, scripts and renders provide the supporting artifacts. Early events are explicitly retrospective entries recorded after execution, not backdated logs.

The user refers to GPT-Astro/Astra. The existing Spatial Assembly application documents `gpt-6-astra` as its generation model. This authoring task runs through Codex; its exact configured model identifier has not yet been independently exposed by runtime metadata. Research-agent use is separately identified. We will not attribute Blender calculations or a terminal download to a model API call that did not occur.

## 2026-09-08 — intake and evidence acquisition

- Read the generate-quest-experience production procedures: source-based reconstruction, editable geometry, material/lighting separation, bounded specialist ownership, actual image inspection and durable handoffs.
- Cloned `abharw/astra2026`, branch `Akeil`, at commit `4992b577191270b84d4923acb167baab31b68e92`. Existing AR application files are preserved.
- Compared two evidence routes: conventional 19-inch APC/Dell equipment with service manuals; Open Compute equipment with potentially redistributable mechanical CAD, electrical schematics and board design data.
- Searched Dell R740 technical/service documentation, APC AR3100 rack drawings, Intel LGA3647 mechanical documentation and NetBotz management/Modbus wiring references.
- Dispatched one bounded OCP acquisition specialist to inspect actual design archives and licenses. This is concurrent research, not additional rendering hardware.
- Initial discovery: official Dell service documentation identifies internal assemblies; Intel publishes socket/package mechanical drawings; Schneider publishes NetBotz wiring information. OCP legacy download access varies, so the specialist is checking official GitHub archives.
- Operations so far used web tools and terminal commands. No rack-task GUI computer-use operation has occurred yet. Later GUI actions will be recorded with their actual purpose and evidence.

## Evidence policy

An attractive reconstruction is not proof of engineering equivalence. Asset metadata will expose source support and unresolved dimensions. Geometric fidelity, Blender appearance, interactive selection, AR placement and robotics dynamics are separate claims with separate tests.

## 2026-09-08 — source conversion and assembly

- Acquired the actual 1.01 GB detailed EVT STEP plus matching electrical archives. Converted it with OpenCascade/XCAF, preserving 9,940 occurrences and 1,241 definitions. The first complete derivative has 18,502,732 triangles across unique meshes; it is a source library containing alternative configurations.
- Imported the derivative into Blender 5.3.0 Alpha and inspected its actual Workbench image. The source coordinate system and several exploded alternatives required correction/selection before a rack could be assembled.
- Constructed 6,663 source-listed PCB parts and independently checked fabrication map registration. Matching CAD connectors are substituted through an explicit skip list to avoid double population.
- Authored the Open Rack V2 frame and power-shelf exterior from separate public mechanical references, keeping inferred integration dimensions in metadata.
- Built and checked the Rack Lab inspection controls, including save/reopen and reversible visibility/transform behavior. Final native-model clicks remain a separate check.
- Selected the actual Blender window through computer use and observed its untitled state. This is the first recorded GUI action for this asset; it does not retroactively describe previous CLI operations as GUI work.
- Identified Apple M5 Pro Metal rendering and native USD/USDZ export support in the installed Blender build. Started the integrated source-registered server build and its first lit preview.

The narrative for judges is in `HACKATHON_PROCESS.md`. Current build, configuration and diagnostic receipts carry the detailed counts and unresolved findings.
