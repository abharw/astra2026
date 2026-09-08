# Rack frame source and rights register

Retrieved 2026-09-08. Authored module is a modified visual reconstruction, not original manufacturer CAD. All trademarks remain their owners'. Source PDFs and associated raster pages are retained here for local evidence and review; do not assume that a public download grants general redistribution rights.

| File | Source / contributor | Rights evidence | Use |
|---|---|---|---|
| standard.pdf | Open Compute Project, Open Rack Standard V2.0; Steve Mills | PDF p9 license: OCPHL-P; local ocphl-permissive-v10.pdf | Primary rack interface |
| facebook-rack-v2.pdf | Facebook, Open Rack Specification V2 rev12; part06-000060 | PDF p4: OCPHL-R; local ocphl-r-copyleft-v10.pdf | Envelope, feet, casters, paint, optional kits. No full manufacturer2D drawing acquired. Preserve reciprocal source license notice. |
| standard-v2.2.pdf | Rittal / OCP, Open Rack Standard V2.2 | Embedded source license; retained comparison only | Checked whether deep48V datum resolved; fig7 still enumerates12Vdeep/48Vshallow |
| ge-48v-shelf.pdf | GE Critical Power, Paul Smith, True Three Phase380–480VAC to48Vdc Power Shelf | Slide5 identifies OWF CLA1.0 contribution by General Electric; no separate signed license retrieved | Rejected shallow-rack shelf; retained evidence only |
| bel-spstet4-07.pdf | Bel Power Solutions, BCD00965rev004,2019-05-27 | Copyright2019Bel; no open hardware redistribution license found | Selected deep48V shelf facts and exterior drawings. Exclude PDF/raster replicas from public redistribution unless permission or another valid basis is established. Authored reconstruction does not embed the PDF/image. |
| bel-tet4000-ra.pdf | Bel Power Solutions, BCD00883_B,2023 | Copyright2023Bel; no open hardware redistribution license found | Exact PSU casing dimensions and connector identity. Exclude PDF/raster replicas from public redistribution unless permission or another valid basis is established. |

Primary logical URLs (the public official staging mirror was used to acquire the OCP documents because their main endpoint returned403):

- https://www.opencompute.org/documents/openrack-standard-v20-overview
- https://www.opencompute.org/documents/open-rack-v2-specification-rev12-pdf
- https://www.opencompute.org/documents/rittal-open-rack-standard-v2-2-proposed-cl-2-pdf
- https://www.opencompute.org/documents/ocphl-r-copyleft-v10
- https://www.opencompute.org/documents/ocphl-permissive-v10
- https://opencompute.org/files/OCP-Summit-GE-True-Three-Phase-380-480VAC-to-48VDC-Power-Shelf-V3.4.pdf
- https://www.belfuse.com/resources/datasheets/powersolutions/ds-bps-spstet-07.pdf
- https://www.belfuse.com/resources/datasheets/powersolutions/ds-bps-tet4000-48-069ra.pdf

Additional inspected evidence:

- https://www.opencompute.org/index.php/blog/ocp-releases-agenda-for-engineering-workshops-at-dcds-colo-and-cloud-dallas-tx-on-25-september-2017 — explicit proposed deep48V datum change.
- https://www.opencompute.org/events/past-events/2018-ocp-rack-and-power-workshop — actual2018rack/power talks; slide link403.
- https://www.rittal.com/com-en/ebook/en_betop_01_2017/downloads/livebook.pdf — primary Rittal2017 product mention; no exact mechanical deep48V proof obtained.
- https://www.opencompute.org/files/OCP-PDF-Adi-Gangidi-Accelerator.pdf — OCP presenter explicitly calls BarreleyeG2 full-depth48VORv2; server integration still awaits actual CAD match.
- https://www.belfuse.com/products/power-supplies/ac-dc-converters/front-end/tet4000-48-069ra — live product page advertises3D viewer; author inspected public frontend implementation without submitting a contact/download request. No3Dvendor file adopted.

Local HTML/JS captures are source-discovery evidence, not authoring dependencies or permission to redistribute third-party website code. Preserve their provenance but omit from a public asset distribution. The Blender source has no external textures or binary vendor models; all its geometry and text were authored from facts and diagrams with individual evidence flags.

The source manifest hashes every retained local evidence file plus the authored module, standalone Blender file, and module documentation. `public_distribution` is a packaging recommendation based on the known evidence, not a legal determination. HTML/JS and Bel/GE PDF/image captures are local research evidence only. Preserve the OCP source attribution and license files with applicable distributed source.
