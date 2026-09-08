# GPT-Astra spatial experiment: actual workflow record

September 8, 2026. This records the visible actions, tools, evidence, intermediate mistakes and decisions in this task. It is an operational account, not a transcript of hidden model reasoning or a screen recording. The model selected evidence, inspected returned images, formed hypotheses and chose rechecks. Local tools performed browser control, media decoding, file conversion and document creation. No second model inference API was called for these experiments.

## 1. Intake, prior work and repository

The user requested an update to `abharw/astra2026`, branch `Akeil`, about the previously recreated adaptive-video skill, then independent experiments on two supplied MOVs, public YouTube comparison, room/wall hypotheses and human checking. The user clarified an email-related typo, emphasized using their videos and the exact skill, added Airbnb photo experiments, and finally requested guided-tour **data only**, with no panorama/3D generation.

Read the existing development journal and repository import notes after cloning the requested branch. Read the installed `agentic-video/SKILL.md`, its tool reference and relevant runtime code. Consulted the prior skill-creation record so the journal labels that work retrospective: its reported ten contract tests were not rerun here. The current experiment does execute the installed skill on real sources.

## 2. Video evidence acquisition and interpretation

The installed launcher was `~/.codex/skills/agentic-video/scripts/video`. Its runtime uses local PyAV/Pillow and FFmpeg. Source initialization collected hashes, dimensions, duration, packet timing and stream metadata. Each video received its own session; no geometry was transferred between the two different places.

| Source | Actual requested visual evidence | Viewed result |
|---|---|---|
| Home, 57.79 s | Whole-clip overview at about 0.2 fps, width 960; whole-clip 1 fps pass at width 1920; 28–43 s and 47–57.79 s at 2 fps, width 1920 | 122 extracted frame records viewed; 13 individual reopens |
| Hall, 48.16 s | Whole-clip overview at about 0.2 fps, width 960; whole-clip 1 fps pass, width 1920 | 59 records viewed; 3 individual reopens |
| YouTube, 182.72 s | 36-frame overview; 8–13 s and 139–144 s at 1 fps, width 1920 | 46 records viewed in sheets |

Used `scan`/`inspect` to request evidence, `view_image` to actually inspect contact sheets and selected single frames, then `mark` to record what was viewed. Used `claim` to distinguish observed, inferred and unresolved assertions and `status` to verify view coverage and request completion. Exact recorded command arguments and timestamps are retained in the per-source `actions.jsonl` files, and frame IDs/PTS/path/size/view state in session manifests. All requests completed without truncation. Repeated timestamps across requests mean these counts are records, not unique moments. Audio was not verified. Source MOVs were 4K; inspected reopens were 960/1920 wide. HDR was not reference-tone-mapped.

The overview showed the sources depict different locations: a hall pan and a furnished-home walk. Full chronological sampling established wall identities and traversed doorways. Denser home intervals targeted the dark bathroom entry, the reversal toward the bedroom, and the dining/kitchen turn. No automatic floor-plan solver, SfM, depth network or pose estimation was run.

**Actual correction:** the first user-check question placed kitchen left of dining. Rewatching the final turn showed kitchen right on entry from the hall: 48.535 s co-shows dining windows and kitchen, while the 57 s fireplace mirror provides a reflected reverse view. The report and drawing were corrected. The candidate second study entrance remained inferred because the doorway was not traversed. Human ground-truth confirmation is pending.

## 3. YouTube computer use

Opened YouTube in the in-app browser, searched “small apartment walkthrough one take,” read the accessible search results, and visually inspected the result-page screenshot. Opened the observed Apartment Therapy link for Kim White's studio: https://www.youtube.com/watch?v=_6z2SII3nHc . An Architectural Digest tour was also discovered but not analyzed.

Acquired the selected accessible public video with `yt-dlp`, then used the same installed skill locally. A transient browser player duration differed during loading; decoded source duration defines the analysis timeline. The selected tour was edited despite the search phrase, so cut order was not treated as a walking route. Targeted wide shots checked whether the sofa/fireplace/window and kitchenette relationships were co-visible. Bathroom access remained unresolved.

## 4. Airbnb computer use and asset handling

Opened `https://www.airbnb.com/s/San-Francisco--CA/homes` through browser control, dismissed the informational pricing modal, inspected result cards and chose two observed listing links. No sign-in, booking, host contact or account mutation was performed.

**Listing A, 1586369805694396546:** opened the listing, read controls, selected **Show all photos**, then scrolled the photo tour through living, kitchen, bedrooms, bathroom, workspace, exterior and additional photos. Used accessibility/UI state and screenshots to inspect the gallery. Repeated downward scrolling loaded the bottom of the gallery. The browser's `pageAssets` capability listed the loaded images; assets were filtered to this listing and deduplicated by source filename. Requested the largest observed variants: 18 succeeded and four 2560-pixel exports failed. Retried those four using their already-observed 720-pixel variants; all succeeded.

Decoded the returned AVIF-in-JPEG-named assets with Pillow to PNG; made four indexed contact sheets, actually viewed all 22 photos, then reopened A11/A12/A14 individually to inspect bedroom/workspace connections. This is format conversion and contact-sheet assembly, not visual generation. Recorded IDs, source URLs, content hashes, dimensions, viewing mode and short observations in a manifest. Matched entrance vase/bench/art, living furniture, arched mirror and bedroom anchors. Kept uncertain bedroom joins dashed and left bathroom access unresolved.

**Listing B, 18981477:** navigated to the observed link, retrieved DOM controls, clicked **Show all photos**, viewed the initial gallery screenshot, and scrolled downward three times with screenshots. Listed loaded `pageAssets`, filtered the nine listing interior/detail assets plus two observed informational graphics, deduplicated sizes, and bundled all 11 successfully. Converted to PNG, composed two sheets, viewed every asset and reopened B05 individually to check the bathroom approach. Matched fireplace/bed within one room and reverse French-door views into the sofa/dining room. Closet and kitchenette access stayed unresolved.

**Evaluation contamination:** listing text and room labels were exposed during navigation, especially the second DOM snapshot. Calling these blind image-only tests would be inaccurate. Final adjacency claims cite visual anchors; the experiment cannot prove independence from textual exposure. No external floor plan was consulted or observed in either gallery. Informational graphics and a neighborhood image were not counted as room evidence.

The CUA calls included browser selection/navigation, accessible state or DOM snapshots, screenshots, **Show all photos** button clicks, coordinate-based gallery scrolling, `capabilities.get('pageAssets')`, `pageAssets.list()` and `pageAssets.bundle()`. Asset exports supplied the local files for detailed inspection; screenshots showed the browser interaction state. This record summarizes operational steps rather than claiming a separately recorded continuous screen capture.

## 5. Guided-tour data from both supplied videos

Read `video-to-walkthrough/SKILL.md` and its reconstruction/completion references for planning. Ran its environment doctor: FFmpeg/FFprobe/Node were present; COLMAP and Nerfstudio commands were absent. Did not run preparation, training, stitching or generation. Reused the already-viewed video evidence.

A local script assembled nine proposed home tour points and one candidate hall pan station. It selected 40 references from viewed manifest records and copied those existing frames into a portable output folder. Each point includes actual PTS/time, local viewing direction, observed wall/furniture anchors, missing or ambiguous views, proposed next points, recapture instructions and conditional constraints for any later authorized completion. The dining point explicitly records two source intervals for entry/revisit. Its two views are not assumed to share a camera center.

Camera pose, metric coordinates, yaw/pitch and coverage percentage are null. Every point has `panorama_ready: false`. A short bedroom glimpse does not become a complete room; the hall's repeated pans do not prove a fixed-center 360 sphere. Mirror reflections are not geometry. No panorama, depth map, mesh, splat, rendered 3D scene or synthesized room image was generated.

## 6. Outputs, verification and publication

Created schematic home/hall floor plans, a public-video diagram, the Airbnb topology graph, written findings, machine-readable evidence/relationships, and the video tour-point plan. Used Python/Pillow/SVG for 2D diagrams and inspected the rendered diagrams. These are evidence diagrams, not generated walkthrough imagery. Source video sessions/action ledgers remain local with the user's detailed spatial evidence.

The first journal publication used GitHub's Git Data API after `git push` failed because of local Git URL/auth configuration. Created blobs/tree/commit and advanced only `Akeil` with `force: false`, then verified the remote commit/tree. The follow-up publication preserves that remote parent and adds the Airbnb/tour methodology and this process account. No application code changed; validation checks document links, JSON references, exact source timestamps, viewed flags, artifact presence and whitespace rather than rerunning unrelated app tests.

Private source videos, home/hall images and detailed room data remain local, following the repository's existing import practice. Public documents include method, aggregate results, public-listing relationships and source links. Logs omit credentials and incidental account data. This task does not establish a measured plan, complete building coverage, calibrated 3D reconstruction or an accuracy score.

## Published companion records

- [Video experiment](VIDEO_FLOOR_PLAN_EXPERIMENT.md)
- [Airbnb comparison and tour-data protocol](PHOTO_AND_TOUR_EXPERIMENT.md)
- [Sanitized actual video command ledger](video-experiment/command-ledger.json)

The private 10-point/40-reference JSON, video images, source manifests, and detailed spatial diagrams are retained in the local deliverables. Browser photo IDs/source URLs and observations are available locally; public diagrams contain only the inferred topology.
