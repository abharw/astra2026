# Data-center POV video: production journey

September 8, 2026. Regular 16:9 phone-like POV video, not Quest or spherical media. This is a fictional authored data-center room using the existing source-based rack asset; it is not a scan of a real facility.

## Initial generation experiments

The user supplied the rack image and requested a short photoreal first-person walk with a look around. Four Seedance 2.0 attempts were completed at 4K. The prompts changed in response to user feedback, so these are creative iterations, not a controlled model comparison.

| Attempt | Duration | Outcome |
|---|---|---|
| Entrance and turn | 15 s | Reviewed samples: attractive room, camera translation during intended turn; floor/ceiling coverage incomplete. |
| Fixed-position turn retry | 15 s | Generation completed; not visually accepted or fully inspected. User redirected toward phone motion. |
| Smooth phone pan | 10 s | Reviewed samples: visible hand enters, final direction does not match start. |
| Precise timed walk and 360 turn | 15 s | Reviewed at 2 fps: walk lasts longer than prompt, wide-angle distortion, turn does not close. User rejected floor-plan/world logic. |

The fourth prompt prescribed motion but provided no persistent geometric scene. Its timing, rack identity, unseen walls and reverse view were left to generative inference. Wording alone did not establish a consistent floor plan. Two waiting requests returned transient API errors; each existing job was recovered, not resubmitted under a new ID.

## User correction and method change

The user asked to research and watch Blender/image/video workflow tutorials, correct the floor plan, render a consistent walkthrough and log the whole process. They then explicitly clarified that this is not Quest and supplied https://www.youtube.com/watch?v=OiULPvTJ-0E (Higgsfield, How To Save AI Credits With Higgsfield + Blender).

The supplied tutorial is being studied through decoded timestamped frames and publisher automatic captions. Its relevant method is editable Blender blocking → inspect camera animation → export a reference video → submit that video plus appearance references and a timestamped prompt. Tutorial demonstrations do not guarantee metric scene preservation by a generative model.

## Production status

Research and fixed-world authoring in progress. No corrected video has passed review yet. Original generations remain preserved locally. Further entries will record actual renders, source hashes, checks and failures.

### Tutorial inspection and adopted method

Supplied tutorial: [Higgsfield + Blender workflow](https://www.youtube.com/watch?v=OiULPvTJ-0E). Downloaded public 1280×720 video (1187.458 s) and publisher automatic English captions. Actually viewed 36 chronological overview frames, plus 12 frames at 180–290 s and 12 at 660–797.5 s; automatic caption excerpts were read. This is sampled visual study, not continuous audio listening. At 210 s the output controls are shown, 240–250 s the blocking/appearance attachments and generation prompt, 260–280 s the side-by-side blocking/result, and 685–697.5 s the editable motion staging. Caption section 11:51–11:58 assigns motion/timing to graybox and visuals to references.

Also inspected 12 sampled frames through the 59.5 s MK Graphics Follow Path tutorial: https://www.youtube.com/watch?v=u1jAqZyxsNA . Read [Higgsfield official Blender workflow](https://higgsfield.ai/blog/higgsfield-blender-plugin). A separate Creative Pad Media continuity tutorial was downloaded but not yet visually reviewed, so it is not counted as watched evidence.

Applied here: one editable geometric room, repeated instances of the saved rack exterior, a fixed-lens eye-height camera with explicit transforms at every frame, then an actual rendered reference clip. Appearance references cannot override the floor-plan authority. Output review must compare landmarks and route; model guidance is not a hard geometry constraint.

### First local build

The local Blender 5.3 Alpha engine enum is BLENDER_EEVEE, not BLENDER_EEVEE_NEXT. First build stopped before saving/rendering; corrected the enum and restarted. This compatibility failure is recorded rather than treated as a generated-video attempt.

### Geometry and render corrections before animation

The 8×10×3.4 m main room now contains 14 rack instances (two rows of seven), two fixed end openings, a closed north service door with an amber panel, and a south entry vestibule with a blue rear panel. The camera walks 2.2 m in four seconds at 1.65 m eye height, then turns through 360 degrees over ten seconds and holds for the final second. Fixed 26 mm rectilinear lens, 24 fps, 360 frames. This is a conventional flat video, not an equirectangular or headset deliverable.

Viewed six directional timing previews. The reverse view initially needed actual space beyond the entrance, so a bounded vestibule was added. EEVEE emitted shadow-buffer exhaustion with the default 512 MB pool; increased to 1024 MB and the six-view render completed without that warning.

An evaluated-bound check found two PSU meshes at about 3.86 m in the imported rack collection, above the 3.4 m ceiling. Their vertices carried a doubled 1.908 m shelf offset. Corrected the two appended-copy meshes by -1.908 m in Z and recorded the local repair in floor-plan.json; the delivered rack library is unchanged. This is a local geometry finding, not a generative-model error.

The complete reference animation is now rendering in recoverable PNG frames. The source Blend file, script, floor plan and every camera pose are saved beside this journal.

The secondary Creative Pad Media tutorial was subsequently inspected at 11 frames from 190–290 s: visible reference-video selection/trim dialog and result comparison. It supports the reference-input workflow; it does not prove arbitrary floor-plan fidelity.

### Motion-reference scheduling

The initial detailed EEVEE animation measured about 3.7 s/frame. A full-detail Workbench comparison was slower (about 10 s/frame), so it was stopped after a few preserved frames. The final motion-reference path uses graybox rack proxies derived from the evaluated rack bounds, retaining the same room, camera, openings, signs, tray geometry and numbered server slots. Lit source images supply surface appearance, matching the supplied tutorial's division of responsibilities. The detailed .blend remains intact and renderable. No partially rendered sequence is called a finished clip.

All 360 camera poses were checked against conservative rack bounding boxes with a 0.25 m camera-body radius: minimum clearance about 0.481 m, no racks above the ceiling, effectively zero translation during the turn, and exactly 360 degrees of yaw. These checks validate the authored reference, not the generated derivative.

## Maze revision requested by the user

The user then requested a maze-like route: straight, left, right, left, with pans, specifically to demonstrate their system's ability to infer floor maps from video. The straight-room source and motion reference were preserved as superseded artifacts. No new cloud generation had been submitted when this change arrived.

The replacement is a continuous 30-second walk through four connected server galleries, covering 24 m with three physically open junctions. Fixed amber, cyan and red junction panels and a green destination door supply correspondence cues without overlaying the answer. The source floor-plan JSON and image stay separate from the video-only mapping input. A generated appearance pass must be checked against the source; it cannot be assumed to inherit exact metric ground truth.

### Maze source verification

Built four connected galleries, 30 rack instances and a continuous 24 m route. Checked all 720 camera positions against wall and evaluated rack bounds: minimum clearance for a 0.25 m camera radius was 0.788 m; no camera positions outside the floor, no rack/rack intersections and no rack/wall intersections were detected. Nine directional previews were inspected in a contact sheet. Two west-wall labels faced outward and appeared mirrored; their normals were corrected and the source regenerated.

Replaced repeated context-sensitive Blender cube operators with direct mesh creation to reduce construction time. This preserves dimensions and avoids repeatedly updating thousands of selected objects. The rebuilt geometry checks passed. The motion reference is a separate graybox render, with the same walls and camera, following the user-supplied tutorial.

### Reference rendered and cloud generation submitted

Rendered all 720 graybox frames, encoded an exact 30.000-second 1280×720/24 fps H.264 reference, and viewed 30 decoded frames at one-second intervals across the whole route. Amber, cyan, red and green anchors appear in the planned sequence; the left/right/left corners are shown continuously in the source animation. All requested overview frames were marked as actually viewed.

The installed FFmpeg lacks zscale. The first encode command failed before producing a clip; used the available colorspace filter with explicit sRGB-to-Rec.709 conversion and tagged the output accordingly. No interpolation or synthetic motion frames were used.

Submitted the exact reference MP4 plus the original rack render to Seedance 2.5 in video_edit mode, 30 seconds, 1080p, high bitrate, with the saved timestamped prompt. The current live model schema supports 1080p despite older installed skill prose saying 720p. Job/result status will be updated from the actual service response. Source hashes are pinned in source-hashes.json.

### Source lighting study and publication

A separate lit-render test found the original area lights were centered behind the overhead cable trays, darkening the room. Moved the render-variant lights to the visible fixture offsets and reviewed front/final-gallery stills. This changes source lighting only; the pinned motion reference, wall topology and camera poses remain unchanged. `render_lit.py` retains the optional variant.

Published the source/checkpoint to the requested Akeil branch. The remote branch advanced during the first push; fetched and merged that independent task's work, preserving both appended journal entries and renumbering the maze entry to 24. LFS source/media objects uploaded successfully. Publication does not constitute visual acceptance of the still-running generated video.

## Final generated result and review

Seedance 2.5 completed the video-edit request. The downloaded original is 1920×1080, 24 fps, 713 decoded frames, 29.708 seconds and 61,454,881 bytes. SHA-256: `1b72ccf37ece8b8aa804b33faf14f9d7245b06d49723f4cb7656720bc3049f2b`. The output is seven frames shorter than the 30-second source; it has not been padded or retimed.

Actually viewed 30 one-second overview records across the entire generated clip, 24 quarter-second records covering the three turns (6–8, 13–15 and 20–22 s), and three final look-back records at 29–29.5 s. All seven contact sheets are retained in `review/`. This is 57 viewed records, including repeated timestamps, not continuous every-frame inspection.

Observed: the amber/cyan/red/green landmark sequence and the straight → left → right → left route match the source. Dense turn samples retain the corresponding rack banks and continuous corners. The final look-back also matches the source's occluded view; a direct comparison of the source frame at 29.5 s confirmed the blank far wall and intervening racks rather than assuming a missing red marker was a failure. Generated lighting, surface detail, added door hardware and motion blur differ from the graybox. No extra route or missing junction was found in the reviewed samples.

This result is accepted for the requested visual maze demo. Exact per-pixel geometry, calibrated metric correspondence, unseen rooms and every-frame artifact freedom were not established. The authored map remains exact for the Blender reference; the generated clip supports a reviewed qualitative topology comparison. Audio is present in the original container but was not listened to or assessed.

Copied the unchanged generated MP4 to `datacenter-maze-walkthrough.mp4` in this package and to the Desktop, with the floor-plan image as a separate Desktop file. The video contains no floor-map overlay. The input-only video can be supplied to the user's mapping system while withholding the answer key and prompts. No claim is made that the user's mapping system was run in this task.


## 2026-09-08 — User correction: natural motion and no wall labels

The first maze render met the left/right/left topology but the user judged it robotic and insufficiently real, and asked for smoother motion/panning and no BAY labels on walls. The source had explicitly stopped for each pivot; that choreography was the root of the mechanical movement. Acceptance of turn order did not establish naturalism.

The revised source in `smooth/` retains the same room and rack footprints, removes every font object, and changes the colored routing panels to neutral unlabelled utility panels and a maintenance door. It replaces stop/pivot phases with 1.6 m rounded corners, continuous translation during rotation, gentle heading anticipation and a slower 6.5-second final 160-degree look-around. The rounded camera route is 21.94 m; room dimensions are unchanged. All 720 camera poses clear the authored walls and racks with a 0.25 m camera radius. Final photoreal output and review pending.
