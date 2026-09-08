# Development journal

All stages below were completed or investigated on September 8, 2026. This journal reconstructs the actual session in order. Repository commits were created afterward and group the existing source for review; they do not recreate a historical commit timeline.

## 1. Establish the interaction with a browser speaker model

**Goal:** take a speaker seen in a photo and explore a holographic assembly.

We authored five Three.js component groups: grille, cabinet, illustrative drivers, hanging bracket and wall mount. Orbit controls, selectable parts, an explosion slider, automatic orbit and hologram/material modes made the interaction concrete. Observed exterior features were distinguished from inferred interior geometry.

The result was deployed as the browser prototype. A runtime issue appeared because React effect callbacks returned the numeric result of an imperative update. These callbacks were changed to return nothing, then the live controls were checked again.

**What this established:** the interaction vocabulary. It did not provide camera tracking, automatic geometry reconstruction or room persistence. The speaker was an authored example, not a general object pipeline.

## 2. Move from the browser to the connected iPhone

**Goal:** point at arbitrary objects on the real phone, ask for reconstruction, and manipulate the result in AR.

We chose SwiftUI for controls, RealityKit for model rendering and interaction, and ARKit world tracking for camera pose and placement. The connected physical iPhone supported LiDAR and ran iOS 26.6.1. XcodeGen made the project configuration reproducible.

A separate Mac bridge holds the OpenAI API key. The iPhone holds a scoped bridge pairing credential and communicates over an authenticated WebSocket through an HTTPS tunnel. The key supplied during development was kept out of source and the app bundle; neither key nor pairing credential is in this repository.

**Evidence:** the app built, installed and launched on the physical phone. Live tracking readiness and the bridge connection were observed during the initial device check.

## 3. Build the actual image-to-component pipeline

The phone captures a real JPEG from the current AR frame, the selected target point, camera pose, viewport transform and a distance estimate. The bridge sends the image itself to `gpt-6-astra` through the Responses API.

The model returns a strict structured assembly: image bounds, estimated dimensions, confidence, component descriptions, evidence labels and bounded primitives. Both bridge and native code validate geometry before rendering. The model does not return executable rendering code.

RealityKit creates boxes, spheres, cylinders, cones and tori from that description. Components are grouped so they can animate independently while belonging to one assembly. This trades geometric fidelity for an inspectable, editable representation.

**Evidence:** a source-photo probe returned eight parts in about 45 seconds. Later actual phone captures produced laptop assemblies in about 56 and 67 seconds, and a six-part wall-mounted speaker in about 32 seconds. These are observed individual runs, not a latency benchmark. Generation is not instantaneous or frame-by-frame reconstruction.

**Limits:** one-view dimensions, rear geometry and hidden components remain estimates. A semantic component list is not an accurate scan or engineering CAD model.

## 4. Add voice tools

The bridge connects to `gpt-realtime-2.1`. The native app streams microphone PCM while voice is enabled and plays returned audio. Realtime invokes tools to request a fresh phone capture or to manipulate an existing assembly. Native command results are returned to the voice session so a spoken success is based on an actual command result.

Commands include explode, assemble, extract, return, move, rotate, scale, select a part, and toggle inferred geometry or rendering style. Movement is constrained while attached: a model must be pulled out before moving, rotating or scaling it.

**Evidence:** a real Realtime probe produced an explode tool call and audio. That is API/tool-path evidence; it does not establish every spoken phrase and every phone audio-route condition.

## 5. Correct the default placement behavior

**User correction:** the generated model should initially overlay its source, remain anchored there, and take apart/reassemble at that same location when tapped.

We added frozen LiDAR depth samples from the selected AR frame, local depth-normal estimation, and raycast/camera-facing fallbacks. The selected image bounds are projected onto an estimated surface plane to estimate extent and scale. The generated model is positioned relative to this source pose.

The renderer saves a home transform. Tap toggles component-local explosion offsets. Translation, rotation and scale gestures remain disabled until **Pull out**; **Return** restores the home transform and assembled state.

**Evidence:** the updated physical build installed successfully. The position logic was implemented, but precise visual fit was not independently demonstrated. The later persistence test checks preservation of the chosen transform, not whether that chosen transform is perfectly aligned to the real speaker.

## 6. Separate room tracking from object tracking

The user asked for Vision Pro-like awareness. We checked Apple's documentation and the implementation rather than describing a world anchor as object recognition.

The code tracks a coordinate in the room. It does not continuously track the physical object's identity or pose after someone picks it up. Apple's reference-object tracking uses a prepared 3D model trained in Create ML; the documented iPhone support requires iOS 27, while the connected phone was on 26.6.1.

A short multiview scan, object isolation and geometric fitting were identified as next steps for better stationary-object alignment. These were discussed, not implemented. Upgrading the OS alone would not create reference models for arbitrary objects.

References: [Apple object tracking](https://developer.apple.com/documentation/visionos/implementing-object-tracking-in-your-app), [iPhone reference-object integration](https://developer.apple.com/documentation/visionos/using-a-reference-object-with-arkit-in-ios).

## 7. Add persistent places and multiple objects

**User correction:** closing the app should not erase objects; returning to a place should bring them back.

We added a local saved-place library. Each file atomically stores an archived `ARWorldMap` and all generated objects: full assembly, ID, home/current transforms, explosion amount, rendering style, inferred-part visibility and extraction state.

The app requests a map about every five seconds when tracking is normal and world mapping is mapped or extending. It displays whether a usable map has been saved. Backgrounding also persists current object state against the cached map. An epoch identifier prevents an asynchronous map callback from an older session writing into a newly selected place.

Starting another reconstruction preserves the previous object in the scene. Tapping a previously placed model selects it as the active model for controls.

On a fresh launch or foreground return with a saved map, the app tries saved places in recency order, with a fifteen-second attempt per candidate. Models are restored only after ARKit has reported relocalizing followed by normal tracking. If none match, a new place starts without overwriting old place files. **Your places** supports an explicit retry or immediate new place.

This is local visual relocalization. A continuous walk remains one AR session/map; automatic geographical room boundaries and universal place recognition are not implemented.

References: [Apple saving/loading world data](https://developer.apple.com/documentation/arkit/saving-and-loading-world-data), [initialWorldMap](https://developer.apple.com/documentation/arkit/arworldtrackingconfiguration/initialworldmap).

## 8. Verify persistence on the actual phone

Four XCTest tests passed: independent saved-place updates with full object state, transform validation, invalid-map rejection and an empty library. Eight bridge validation tests had also passed.

The physical build stalled during an Xcode compiler query. Sampling the compiler showed it blocked writing diagnostic output. For that local build, a temporary compiler wrapper omitted verbose output only for the macro-introspection query; normal compilation still used Apple's compiler. The physical build then succeeded. This workaround is not part of application runtime behavior.

After installation, the user generated a six-part speaker. We observed a saved room file on the phone, then terminated and relaunched the app. The same saved room was restored and autosaved again. A before/after comparison confirmed:

- Same room and object IDs.
- Identical generated assembly geometry.
- Same assembled/exploded state.
- Maximum home/current matrix-element difference approximately 0.0000007.

The sanitized comparison is in [persistence-verification.json](../spatial-assembly/persistence-verification.json). Raw room files and images are excluded because they contain private spatial data.

The Mac phone preview turned black during this phase. Device launch, API activity and saved-file comparison were available, but independent visual alignment verification was not. This test reopened the app in the same location; it did not test leaving, entering another room, and returning later.

## 9. Publish an inspectable development record

The requested empty GitHub repository was initialized with the README-only `first commit` on `main`. The `Akeil` branch imports native source, the original browser source snapshot, configuration helpers, tests, architectural comments and this journal. Credentials, source photos, room maps, build products and hosting metadata were excluded.

## Continuing this journal

For each future change, append a dated entry with: the concrete user-visible problem, the implementation and rationale, tests or device evidence, and any remaining uncertainty. Keep proposals clearly separate from implemented behavior. Do not equate a successful build, generated API output, or matching saved matrices with a visually correct AR experience.

## 10. Recreate an adaptive video-inspection skill (prior work; recorded September 8, 2026)

**Problem:** one image cannot establish room connectivity or the contents of walls outside the current view. We needed Astra to choose which video moments to inspect and revisit them at higher temporal or spatial detail.

A previous session built and installed the local `agentic-video` skill. This entry records that prior work retrospectively; it does not claim the skill was recreated again during this journal update. The existing skill and command documentation were read, and the runtime successfully initialized both supplied MOV files in the current session.

The recreation is of the adaptive tool-use pattern: ask a spatial question, decode timestamped frames locally, inspect them with the current model, select another interval or crop, and record observed/inferred/unresolved claims. PyAV/Pillow and FFmpeg provide evidence, not a second inference model. This does not recreate proprietary model training or establish parity with native audiovisual systems. Previous validation reported ten contract tests plus synthetic and real-video checks; those earlier test results have not yet been rerun in this experiment.

## 11. Single-video floor-plan experiment (September 8, 2026; first hypotheses completed, human check pending)

**User request:** test the two supplied videos separately, infer room arrangement and wall contents, explicitly label unseen completion, browse YouTube for additional examples, log Astra's actual actions, and ask the user to check the resulting spatial interpretation. The user clarified that the phrase about bulk email was a typo and asked to prioritize the supplied videos.

**Protocol:** produce a separate hypothesis from each source before any cross-video comparison. Keep source frames, detailed private spatial maps and raw manifests local. The journal records method and outcomes; a shareable public-video example may be documented separately. Dimensions and compass directions require evidence and must not be invented. Unseen areas can be proposed, with alternatives and a clear inference label.

**Actions so far:** cloned the requested `Akeil` branch; read this journal; read the installed skill and its command reference; initialized source-hashed sessions for the supplied 48.16-second and 57.79-second 4K videos; requested chronological overview frames. Opened YouTube through computer-use browser controls and searched for small-apartment walkthroughs. Search results included Apartment Therapy's Kim White studio tour and an Architectural Digest apartment tour. Search-result discovery is not video viewing; neither public video has been analyzed at this point.

**First observation and adaptation:** the uploaded videos show different places: one is a pan around an event hall, the other a furnished-home walkthrough. The five-second overview is insufficient for doorway topology. Astra actually viewed both overview sheets, then requested a complete one-frame-per-second pass at 1920-pixel width for each original MOV. Individual overview views of the home at approximately 5, 20 and 25 seconds were revisited to inspect the study-to-sitting-room opening, stair landing and corridor jog.

**YouTube acquisition:** after visually inspecting the search page with computer use, opened [Kim White’s studio tour](https://www.youtube.com/watch?v=_6z2SII3nHc) by Apartment Therapy and downloaded the accessible public video with `yt-dlp` into local scratch storage. The downloaded source is approximately 182.72 seconds. The browser initially displayed a different player duration while loading, so source decoding, not that transient player state, defines the analysis clock. A public-video overview was requested as a supplemental comparison; the supplied videos remain the primary tests.

**Second observation and rewatch:** Astra viewed all 49 one-second hall frames and all 58 one-second home frames as chronological contact sheets, then opened selected 1920-pixel home frames individually. The hall's repeated pans support a four-wall arrangement; the home has multiple connected spaces. A two-frame-per-second rewatch of 28–43 seconds was requested and viewed to test bathroom/bedroom doorway placement, including the dark interval before the bathroom lights turn on. A second two-frame-per-second rewatch of 47 seconds through the home clip's end was requested for dining/kitchen/utility relationships.

**Human check requested:** Astra asked the user whether the study-to-sitting-room connection, hall with stairs on the left, bathroom-left/bedroom-right arrangement and dining-to-kitchen relationship match the actual home. This is a hypothesis check, not recorded ground truth; no confirmation had arrived at the time of this entry.

**Public comparison observation:** Astra viewed a 36-frame chronological overview of the Apartment Therapy tour. It contains cuts between interview and detail views, so successive shots cannot automatically establish a camera path. Targeted wide-shot rechecks were requested around 8–13 and 139–144 seconds to establish relationships visible within a single shot. Audio was not verified in any source.

**A meaningful correction from rewatch:** the initial human-check question placed the kitchen on the left of the dining room. The 48.535-second frame shows the dining windows and kitchen together during a rightward turn, and the 57-second reverse view shows the kitchen reflected in the dining fireplace mirror. Astra corrected the hypothesis to **kitchen on the right when entering the dining room from the hall**. The earlier statement is retained here as an actual intermediate error, not silently rewritten as a successful first guess. This illustrates why adjacent wide views and reverse checks matter. The corrected result remains awaiting human verification.

**Deliverables and verification:** created separate local home and hall floor-plan diagrams, a wall-by-wall report with timestamps, a public-tour partial diagram, and machine-readable evidence records. Final skill status showed 122/122 home frame records viewed (13 individual reopens), 59/59 hall records viewed (3 individual reopens), and 46/46 public-video records viewed. These include repeated timestamps, not 227 unique moments. Every request completed without truncation. No audio verification, measured dimension recovery, accuracy score or finished 3D reconstruction is claimed. The private source videos, detailed home/hall diagrams and frame evidence remain local. The method, public comparison and limits are documented in [the experiment report](VIDEO_FLOOR_PLAN_EXPERIMENT.md).

**What this established:** Astra can form an inspectable room/wall hypothesis from one video and use targeted rewatching to correct an orientation error. It does not establish a complete or metrically accurate building plan. Human checking was requested and is pending; the current diagrams can be revised against the user's knowledge. No iPhone application code changed in this experiment.

## 12. Extend the experiment to Airbnb photos and tour-point data (September 8, 2026)

**User direction:** also test public Airbnb images; document Astra's computer use and reconstruction process for the hackathon; prepare video-based guided-tour points with timestamps, observed references and missing-view requirements, without generating panoramas or 3D. Both original videos remained the primary source tests.

**Actual computer use:** browsed two San Francisco listing galleries, scrolled screenshots, exported loaded images with the browser page-assets tool, converted returned formats locally and inspected indexed sheets plus selected individual images. Viewed 22 photos from the garden flat and 11 gallery assets from the suite. Four large-image exports failed; already-observed lower-resolution variants succeeded. Listing prose was exposed in browser snapshots, so the result is explicitly photo-led rather than a blind image-only benchmark.

**Spatial result:** overlapping door/object views support some local relationships, but disconnected photo groups remain unjoined. The suite's fireplace area and bed are co-visible in one room; they were not counted as separate rooms. Bedroom joins, bathroom access and unseen door destinations were not filled with invented geometry. The public [comparison report](PHOTO_AND_TOUR_EXPERIMENT.md) contains a topology schematic and source links.

**Video data result:** assembled nine proposed home points and one hall pan station, with 40 timestamped references to already-viewed frames. Each records observed anchors, missing views and conditional completion constraints. Exact camera positions and 360 coverage were not recovered. All points remain unready for panorama assembly. No panorama, 3D scene or synthetic room imagery was generated.

**Process record:** added [Astra's operational log](ASTRA_PROCESS_LOG.md), including the browser/control sequence, exact video sampling scope, evidence tracking, the corrected kitchen-side mistake, image-export fallback, evaluation contamination, environment check and publication method. A [sanitized command ledger](video-experiment/command-ledger.json) preserves actual skill-command timestamps and arguments; private room imagery and detailed tour JSON remain local. Prior skill recreation is still labeled retrospective, and human layout confirmation remains pending.

**Verification:** checked JSON evidence references against viewed source records, local artifacts and document links, and visually inspected the new topology diagram. No application code changed. The logs distinguish observed evidence, inferred layout and proposed future generation.

## 13. Technical references and Quest POV (September 8, 2026)

Added a two-stage research path: read visible product identity, then request web search for manuals, schematics, parts diagrams and related technical references. Source URLs must be present in the web tool result. Exact-model labels require readable identifying information; similar-model sources cannot promote hidden geometry to documented evidence. Search failure is visible and falls back to image-only geometry.

Expanded the assembly format with component functions, uncertainties, source IDs and bounded custom triangle meshes. The iPhone Parts panel exposes references, explanations and a correction/rebuild action. Revisions retain object identity and original/current placement. Restored scenes synchronize with the bridge for voice context. The bridge adds fresh-camera inspection, part explanation and reference-assisted refinement tools; it freezes revision input during asynchronous research and handles cancellation and device command acknowledgments.

Built a native Unity/OpenXR Quest client around Meta passthrough camera access and environment raycasting. Hand/controller pointing is projected using the camera-associated pose, then frozen for source-plane placement when generation returns. The client implements selection, explosion, pull/return, voice, rebuilding and local Meta spatial-anchor persistence. The original XR configuration was adapted from Meta's public passthrough sample and attributed in quest/NOTICE.md.

A real speaker-photo probe searched manufacturer materials and returned eleven components with 37 primitives, including two custom meshes. The three sources were similar-product references (JBL AC16, JBL AE bracket guidance, Yamaha VXS); the image did not verify an exact model. Search took roughly 35 seconds and the complete pipeline roughly 145 seconds. A real Realtime API probe then explained the selected grille, supplied audio and stated the exact model was unconfirmed. Its device selection acknowledgment was simulated; it is not a headset runtime proof.

Seventeen backend tests passed, including source grounding, mesh validation, restored scene context, search fallback, cancellation and a selection-change race during refinement. Six iPhone XCTest tests passed, covering the prior storage checks plus mesh validation/backward decoding. The research-enabled iPhone app built, installed and launched. Visual fidelity and the new reference/rebuild flow on the physical device remain acceptance work.

Build diagnosis: OpenXR required explicit EditorBuildSettings configuration registration before BuildPipeline; adding this resolved its late-initialization failure. On this Mac, Xcode's clang macro-introspection command can block when verbose output fills its capture path; a local wrapper removes only `-v` for `-dM` invocations. It is not part of portable source requirements and the compiler itself was not modified.

Quest headset acceptance remains pending a USB-authorized Quest 3. The implementation is a generated approximate assembly with sampled POV frames, not an accurate CAD scan, continuous omniscient vision, or a tracker for a moved physical object.

Final software checks: the Quest APK built successfully with camera/scene/anchor/hand/audio/network permissions. Unity checked the real 11-part, 37-primitive response, calibrated capture-ray orientation and return pose. The final pass also guarded concurrent captures and preserved JSON/toolbar members under IL2CPP stripping. No Quest was listed by adb at delivery; hardware acceptance remains pending. Sanitized metrics and public reference links are in RESEARCH_QUEST_VERIFICATION.json.

## 14. Phone computer use and direct tap creation (September 8, 2026)

The user requested a mounted-phone computer-use test and explicit hackathon documentation. Searched for the Astra iPhone-control demonstration, located a matching creator video, and checked Apple's camera/microphone limitation for iPhone Mirroring. Opened Mirroring with native computer use; it is waiting for the user's Mac login. The existing QuickTime iPhone screen preview remained black. Neither observation proves remote touch or live AR success.

Changed the app so tapping a physical surface starts reconstruction by default, with an on-screen toggle for the original target-lock-then-voice workflow. Existing generated-part taps still select/explode. The physical iPhone build passed. See [the phone-control experiment record](PHONE_COMPUTER_USE.md) for source links, actual tool actions, current blockers and the remaining acceptance sequence.

## 15. Direct camera/control workaround (September 8, 2026)

After the user unlocked Mac authentication and locked the phone, Astra controlled the physical iPhone through Mirroring and opened Spatial Assembly. The system visibly rejected camera access, matching Apple's documentation. The user requested a workaround. Added an optional authenticated foreground-only camera/control link inside the app, with fresh ARView snapshots, shared object-tap handling, command acknowledgments and an explicit stop control. Three relay tests and the physical iPhone build passed; the build was installed and launched. See PHONE_COMPUTER_USE.md for setup, the exact distinction from OS computer use, and pending/live evidence.

## 16. Resume control; add drag and typed questions (September 8, 2026)

On resuming, the device reported three saved objects with a seven-part chair selected. Added app-level screen-space dragging after extraction and typed questions about the current object/part, with playback-only audio for typed input. Test state includes transcripts and original/current transforms. Builds and relay validation passed. The initial installation lost the device connection, then installation and launch succeeded after reconnection. A live snapshot from the updated app succeeded; it showed a close-up gray surface during relocalization. Drag and question acceptance remain pending a useful camera view. The camera-link and real mirrored UI results remain separately documented in PHONE_COMPUTER_USE.md.

## 2026-09-08 — Best-fit spatial completion and additional tours

Discovery used web search followed by yt-dlp flat JSON YouTube search; candidate lists are retained under work/new-*-candidates*.jsonl. Selected real interior footage from RentVision and HomeJab, excluding rendered-house examples. Downloaded with yt-dlp, registered independent agentic-video sessions, and viewed initial overview sheets. Saved six predictions in outputs/best-fit-tests/predictions-before-recheck.json before opening targeted checks. Request manifests preserve actual times, PTS, sampling parameters and source hashes.

Targeted rechecks used the installed `video inspect --session ... --start ... --end ... --fps ...` command, then actual model viewing and `video mark`. Separate source decoding used local Python threads, not delegated agents. A denser house recheck separated edited bedroom shots. Four native bathroom frames distinguished two toilets from a reflection. All 171 apartment and 134 house extracted records were viewed; none of these requests was truncated. The studio received 22 more viewed records and three individual reopens, bringing its total to 68.

All three apartment predictions were supported. House corridor topology was partly supported; bathroom compartment interpretation was corrected; fireplace-side laundry placement was rejected in favor of kitchen-to-utility-to-concrete-patio. Studio rewatch revealed a folding wall bed and identified the center window panel as a mirror. These are within-source checks, without a measured ground-truth floor plan.

Created seven best-fit schematics, 27 assumption records and selected completions for all 29 supplied-video gaps. Retained earlier conservative diagrams. Inspected the atlas and fixed cramped labels; validated cited evidence IDs/viewed state and gap coverage. Updated aggregate evidence counts, framework, report and download bundle. The plots are unmeasured diagram coordinates, not recovered geometry. No panorama/3D generation ran. A shell attempt using `python` failed because only `python3` was available; reran successfully with python3.


[Reusable workflow](SPATIAL_WORKFLOW.md) · [Test report and public-source plans](SPATIAL_BEST_FIT_TESTS.md).
