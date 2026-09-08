# Complete spatial-analysis deliverables

This directory contains the delivered analysis artifacts for five videos and two Airbnb photo sets, including the two supplied-video plans and their panorama planning data.

- [Panorama stops, available footage and missing views](guided-tour-plan.md)
- [Panorama planning JSON: 10 points and 40 timestamped frame references](guided-tour-data.json)
- [All seven best-fit plans and reasoning](best-fit-floor-plans.md)
- [Assumption ledger: 27 layout choices and 29 tour-gap completions](best-fit-assumptions.json)
- [Reusable workflow](reusable-spatial-workflow.md)
- [Additional walkthrough tests](best-fit-tests/report.md)
- [Full process log](astra-process-log.md)
- [Original video analysis](floor-plan-experiment.md) and [Airbnb analysis](airbnb-experiment.md)
- [Evidence and file-integrity manifest](artifact-manifest.json)

The full panorama-stop inventory currently covers the two supplied videos. The other five places have spatial plans and evidence, but not equivalent detailed panorama inventories. No calibrated camera poses, stitched panoramas or generated 3D are claimed.

All linked tour frames, photo evidence, contact sheets, diagrams and JSON records are included. Native source videos are retained outside Git; filenames and hashes identify them. Frame records without an individually exported image remain available within their indexed contact sheets. Session `path` values are relative to this directory when an asset is included, otherwise null. Historical action logs retain the original execution paths as provenance.

ZIP downloads are omitted because they duplicate these same files. The branch-level build journal remains at [BUILD_JOURNAL.md](../BUILD_JOURNAL.md).
