# Repeating the video/image-to-spatial-plan workflow

This workflow accepts one video or a set of photos. It produces an evidence-linked room/connection hypothesis, wall inventory, proposed tour points and a missing-view list. It currently combines the installed `agentic-video` skill, browser/image inspection, `video-to-walkthrough` planning guidance and report assembly. It is not a single automated floor-plan reconstruction command. The guide now includes a best-fit completion pass and a prospective prediction/recheck protocol; two additional tours have now exercised that protocol.

## The loop

**Input → overview → rooms and anchors → evidence map → best-fit completion → targeted challenge → completed plan + gaps → tour data.**

| Stage | Video | Photos | Saved result |
|---|---|---|---|
| Register source | Hash video; inspect duration, rotation and presentation timestamps. Keep separate sessions for different places. | Record source URL/name/hash and dimensions; deduplicate image variants. | Source manifest |
| Survey | Inspect a chronological overview, then enough temporal detail to follow transitions. | Inspect every image in indexed sheets; group recurring visual anchors. | Viewed evidence index |
| Identify spaces | Track doors, windows, wall details and camera movement into/out of rooms. | Match distinctive furniture, doors and wall details across photos. | Room and wall inventory |
| Connect spaces | Prefer observed doorway traversal and continuous co-visibility. Note edits. | Prefer co-visible openings and reverse views. Gallery order is not adjacency. | Graph of observed/inferred connections |
| Challenge the map | Revisit turns, dark intervals, returns and ambiguous doors with denser sampling or larger frames. | Reopen ambiguous photos at larger size; compare mirror and doorway geometry. | Corrections and unresolved alternatives |
| Complete likely layout | Choose likely hidden connections from camera turns and return paths; preserve alternatives. | Join photo groups using matched anchors and minimal plausible circulation. | Best-fit plan + assumption ledger |
| Find gaps | Per proposed viewpoint, list unseen directions, floor/ceiling and occluded surfaces. | List unseen walls and missing linking views between groups. | Missing-view and recapture checklist |
| Prepare tour | Choose candidate stops; attach actual timestamps/frames, anchors and next stops. | Choose photo-supported stops; attach image IDs and connection evidence. | Tour JSON, readable plan and schematic |

Sampling is adaptive. The approximately 5-second overview, full 1-fps pass and selected 2-fps rechecks used for the short supplied videos were choices for these clips, not universal settings. Brief transitions may require dense frame-by-frame inspection. More extracted frames count as evidence only after they have actually been viewed.

## Evidence model

Keep four linked records:

1. **Evidence:** source ID, frame/image ID, timestamp and PTS when applicable, file, resolution/crop, actual viewing state.
2. **Space:** room ID, descriptive name, wall anchors, openings, supporting evidence and unresolved boundaries.
3. **Connection:** from/to room, observed traversal or co-visibility versus inferred match, supporting evidence and alternatives.
4. **Tour point:** candidate viewpoint, references, visible anchors, missing views, next points and required capture.

Each claim is observed, inferred or unresolved. A room's existence may be observed while its connection or shape remains inferred. Do not compress those into one confidence label. Keep dimensions, compass directions, camera pose and coverage percentage unset unless they are actually recovered.

The current concrete examples are [the tour JSON](SPATIAL_BEST_FIT_TESTS.md), [video claims](SPATIAL_BEST_FIT_TESTS.md), [photo relationships](SPATIAL_BEST_FIT_TESTS.md) and [photo evidence manifest](SPATIAL_BEST_FIT_TESTS.md). These are example records, not yet a unified packaged schema for every stage.

## What “missing” means

- **Unseen surface:** the camera never showed the entrance-side wall, ceiling or floor.
- **Occluded surface:** furniture, a person or curtains hide it.
- **Uncertain connection:** a doorway is visible but its destination is not established.
- **Uncertain geometry:** wall extent, bay angle, depth or scale is unmeasured.
- **Incompatible viewpoints:** opposite views come from different camera centers and cannot simply become one panorama.

A gap record should state what is missing, the evidence establishing that limit, why it matters and the exact next capture that would resolve it. For unseen door destinations, select a minimal plausible access, storage or circulation volume when a completed plan is requested. Label its function and extent as assumptions; the true room count remains unverified.

## Best-fit completion: choose the most plausible whole layout

After mapping observed evidence, produce a completed working hypothesis for every unresolved area. Keep the evidence map unchanged beside it. A usable hypothesis can be wrong and revised; it must be explicitly distinguished from a recovered fact.

1. **List constraints.** Record traversed doors, co-visible anchors, relative turn directions, repeated rooms, exterior windows, likely floor levels, and the observation supporting each. A camera cut removes route continuity. Reflections get their own label.
2. **Propose candidates.** For each gap, generate a preferred connection/room boundary and at least one material alternative. Use the shortest plausible circulation, simple wall continuation, shared room anchors and minimal additional rooms. Common layouts and shared plumbing are weak supporting priors, never substitutes for contradictory pixels.
3. **Rank by consistency.** First reject contradictions to clear observed evidence. Then prefer matches to multiple views and route order, functional circulation without furniture/wall collisions, and the fewest unsupported partitions/rooms. Dimension ratios are illustrative unless calibrated. Do not turn this ranking into a probability of truth.
4. **Choose and draw.** Commit to one best-fit working arrangement rather than leaving every gap blank. Color inferred walls, doors and hidden surfaces amber; annotate the choice ID. For unknown areas beyond doors, model a minimal access/storage/circulation volume with a low-confidence purpose instead of inventing an entire detailed floor.
5. **Freeze predictions before testing.** Save the selected hypothesis, evidence, alternative and expected confirming/contradicting view before opening the targeted recheck. This makes a correction distinguishable from hindsight.
6. **Challenge the uncertain join.** Rewatch preceding/following turns, reverse passes and doorway crossings; inspect additional photos. Promote only newly observed facts. Record supported, contradicted/revised, or still untested outcomes. Where more footage exists, recheck before using a weak architectural prior.
7. **Complete the record.** Every gap has a selected assumption or an explicit geometric placeholder, concise evidence-based rationale, strongest alternative, qualitative confidence, and next capture. Preserve missing-view requirements even after filling the plan: a plausible rear wall does not become observed imagery or 360 coverage.

For images, use object identity, matching door trim and the opposite view to join groups; camera ordering is unavailable. For videos, use motion continuity, doorway traversal, return paths and turns before layout conventions. Export both an evidence-only plan and a best-fit plan so later generation can follow the selected geometry without erasing uncertainty.

Suggested assumption fields: `id`, `gap`, `selected_hypothesis`, `basis_evidence_ids`, `rationale`, `alternative`, `confidence` (high/moderate/low, not calibrated), `contradictions`, `test_prediction`, `test_result`, `status` (inferred/observed_after_recheck/revised), and `affected_plan_elements`.

Completion test: every unresolved area has been addressed; no selected geometry contradicts clear evidence; each best-fit choice is traceable; every new extracted relevant frame is actually viewed; all diagrams and JSON agree. A sparse scan is not a holdout benchmark or ground truth. Separate source consistency from externally verified accuracy.

## Completion criteria

A useful result has an evidence-only map and a completed best-fit map. Every directly observed connection cites evidence, while every inferred connection has a selected hypothesis, alternative, rationale and test. Track actual viewing and distinguish schematic geometry from measurement. Verify timestamps/IDs/files and inspect the final diagrams. Ask someone who knows the property to check remaining topology questions. Do not claim a complete or accurate floor plan just because the JSON is valid.

For an image-only evaluation, hide listing text, room labels and supplied plans before inspection. That was not achieved in the Airbnb runs here, so those are labeled photo-led rather than blind tests.

## Where generation fits

The evidence workflow ends before image or 3D generation. Later completion can use observed anchors as constraints and must label invented surfaces. A generated storyboard can explain the plan, but its illustrations are not source evidence. Recovering metric poses, stitching panoramas or creating 3D requires an additional workflow and additional verification.

## Status of this implementation

- **Already available and exercised:** installed adaptive-video tool, browser/photo acquisition, visual interpretation, evidence tracking, private source manifests and public process logs.
- **Completed for this task:** five video analyses, two photo-led listing analyses, ten proposed points from the supplied videos, forty video references, diagrams and gap lists.
- **Formalized here:** a repeatable framework with mandatory best-fit completion, alternative hypotheses and prospective rechecks.
- **Not yet packaged:** a single reusable command that ingests either modality, runs the entire interpretation loop and emits a common validated project format automatically.

[Review all experiments](SPATIAL_BEST_FIT_TESTS.md) · [Actual operational record](SPATIAL_BEST_FIT_TESTS.md).

## Best-fit pass exercised on seven places

[Seven plans and reasoning](SPATIAL_BEST_FIT_TESTS.md) and [machine-readable assumption ledger](SPATIAL_BEST_FIT_TESTS.md) contain 27 selected layout decisions and 29 explicit tour-gap completions. [Frozen predictions](SPATIAL_BEST_FIT_TESTS.md) and [recheck outcomes](SPATIAL_BEST_FIT_TESTS.md) preserve the before/after test. Three apartment predictions were supported; the house corridor was partly supported, the bathroom was refined, and the utility connection was rejected and revised. These are source-consistency checks, not measured floor-plan accuracy.
