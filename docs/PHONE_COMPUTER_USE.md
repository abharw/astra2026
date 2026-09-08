# Phone computer use and tap-to-create — hackathon record

Recorded September 8, 2026. This extends the native Spatial Assembly work; it is not a claim of completed remote AR testing.

## Request and research

The user asked Astra to operate a mounted physical iPhone, find a Twitter demonstration of phone computer use, use iPhone Mirroring as a fallback, and test tap/voice reconstruction plus movement in the environment.

Search surfaced a Nick Dobos post describing Astra operating the Mac iPhone mirror app, with a reported scrolling limitation. That lead came from a search-indexed third-party profile; opening the profile returned different older content, so the original tweet/permalink has not been independently verified. Do not cite it as reproduced evidence.

A matching published demonstration is Mark Kashef's [GPT-6 Astra’s Computer Use Is Ridiculously Good](https://www.youtube.com/watch?v=tU-fO6cADvQ), linked from [the creator’s own website](https://www.markkashef.com/). A [third-party transcript/summary](https://moderncreator.app/2026-09-05-mark-kashef-gpt-6-astra-s-computer-use-is-ridiculously-good) identifies the iPhone Mirroring segment at about 13:25. We located the original video link, but have not visually reviewed the video in this run.

Apple documents [iPhone Mirroring](https://support.apple.com/en-us/120421) as Mac control of a nearby iPhone. Camera and microphone access are unavailable while mirroring. Consequently, success clicking a mirrored app would not establish camera capture, voice input or AR tracking. The live AR acceptance must run on the unlocked physical phone outside Mirroring, with a compatible viewing/control method.

## Actual computer-use observations

1. Launched the installed Spatial Assembly app on the connected physical iPhone through the device development interface.
2. Inspected QuickTime's Movie Recording screen and selected its iPhone screen input. The preview remained black. This was observation only; QuickTime did not provide remote touch input.
3. Opened the Mac iPhone Mirroring app through native computer use. Its accessibility tree reported a locked window requesting the Mac login.
4. Asked the user to unlock locally without sharing a password. After the user did so, Mirroring changed to iPhone in Use and requested that the physical phone be locked. No credentials were read or entered. The user then locked the phone and Mirroring connected.

5. Through Mirroring, opened Spotlight and clicked the Spatial Assembly icon. The app launched and macOS displayed its camera-unavailable notice. Dismissed it and observed the connected app and new tap-to-create toggle. A changing layout caused an attempted toggle click to land on the microphone; the requested voice permission was allowed. The app showed Listening, but microphone capture was not verified. The camera warning reappeared. This establishes real mirrored UI control and reproduces the camera limitation, not successful AR generation.

## App change

Previously, tapping a physical surface only locked the target; a second button press or voice command started generation. Tap-to-create now defaults on: a successful surface lock immediately invokes the existing research/reconstruction path. A visible toggle preserves lock-first use with voice. Taps on generated parts keep the existing select/explode behavior; busy and relocalization guards remain. Failed surface detection does not trigger reconstruction using an old target. Voice already supports reconstruction, explanation and manipulation; no new voice model is claimed here.

The physical iPhone build passed and the updated app was installed successfully. Subsequent live acceptance is recorded below as it occurs. This small interaction change was checked by compilation and review of the shared capture path; previous unit-test results are documented separately, not relabeled as a new live test.

## Pending acceptance

- Unlock Mirroring and verify ordinary native controls from actual screenshots/accessibility state.
- Exit Mirroring for camera/microphone AR tests. Keep the mounted phone unlocked and aimed at a clear object; move it slightly first if mapping requires it.
- Tap an object and verify one reconstruction starts. Select and explode a generated part. Pull it out, move/rotate, then Return and check the original pose.
- Enable voice on the physical phone; request reconstruction/explanation and compare actual outcomes with the spoken acknowledgment.
- Capture visual evidence and report misalignment, latency or failed actions honestly. No exact CAD reconstruction or successful remote camera/voice test is established by this document.

## Direct camera workaround

Implemented an optional app-level test link. With Mirroring closed and the physical phone unlocked, Spatial Assembly can send an actual RealityKit ARView JPEG on request and accept bounded actions: object tap, reconstruction, explanation, refinement, voice start/stop, cancellation and model manipulation. Object taps call the same native handler as touchscreen taps. This is explicit application control, not OS-wide touch injection.

The link displays its status and a stop control, disables auto-lock while enabled, and shuts down when the app leaves the foreground. Snapshots require a recent AR frame; missing/stale camera frames return an error. Snapshots include camera and virtual geometry, not the native toolbar. The Mac relay retains requests only in memory and returns the phone's acknowledgment. The CLI saves an image only when an output path is supplied. Separate private device and admin credentials authenticate the relay; no OpenAI key is needed for camera viewing. Generation/voice continue through the existing OpenAI bridge.

### Reproduce

1. Run the generation bridge normally.
2. Start an HTTPS tunnel to localhost:8798. Run `python3 spatial-assembly/configure-camera-test.py https://YOUR-CONTROL-TUNNEL` after normal pairing.
3. Run `node spatial-assembly/server/device-control.mjs` and rebuild/install the iPhone app.
4. Close iPhone Mirroring. Unlock the mounted physical phone, open Spatial Assembly and enable Mac camera test. A debug launch with `--mac-camera-test` enables this explicitly for the current test run.
5. Use `python3 spatial-assembly/server/control-phone.py snapshot --output /private/path/frame.jpg`, inspect the image, then `tap --x 0.5 --y 0.5` for a normalized point in that AR view. Never choose points without inspecting a fresh image.
6. Poll `state` for generation completion. Use `manipulate --operation extract`, bounded movement and `manipulate --operation return`; compare fresh snapshots. Stop the link in the app when finished.

Three relay tests passed: separate credential enforcement/disconnected response, actual device acknowledgment and request-ID handling, and rejection of invalid taps/arbitrary commands. The updated physical-phone build passed and was installed/launched. Live camera and manipulation results will be appended after the mounted phone is ready.

### First direct-camera proof

The phone connected after a debug launch with `--mac-camera-test`. A requested ARView snapshot succeeded and was visually inspected: it showed the real backpack, floor, table, chairs and plants. The response reported a fresh camera frame (about 0.05 seconds old). Tracking transitioned from saved-room relocalization to Tracking ready. An app-level tap at normalized (0.37, 0.75), chosen from that actual image over the backpack, invoked the shared native tap handler and returned `busy: true` with reconstruction started. Generation and subsequent manipulation are still in progress at this entry. The raw image stays in private local evidence, not the public repository.

The direct link subsequently disconnected before the backpack generation result could be inspected. No completed backpack reconstruction, drag, movement or Return result is claimed for this attempt. Further control actions were paused for clarification of the user’s computer-use instruction.

### Resume, saved objects and drag/question extension

After the user asked to continue, the app-level link reconnected. The device reported three saved objects, with a seven-part gray upholstered sled-base chair active and tracking ready. This was a state observation; we did not create or visually validate all three objects in this control run.

Added normalized screen-space dragging for the selected extracted model. It intersects the start/end viewing rays with a plane through the model, moves by the resulting displacement and retains the original home transform. Moves longer than two metres and invalid coordinates are rejected. Native touch translation/rotation/scale gestures were already enabled after Pull out; the new command exposes dragging through the Mac test link.

Added an Ask field in Parts and an app-level `ask --question` command. Typed questions synchronize the selected object/part into the existing Realtime context and play the answer without opening the microphone. A stop-answer control ends playback; spoken voice remains separately enabled. The test state now exposes transcript, object list and original/current transforms so later movement/Return checks can compare actual state with images.

The extension's physical iPhone build passed. During installation the device connection closed and Xcode reported the phone unavailable, so installation of the drag/question extension and its live acceptance remain pending. The previous camera-link build had already installed and returned a real camera image. Relay tests also reject out-of-range drags and empty questions. Do not describe the untested extension as a completed physical drag or question demonstration.

Example after reconnection: inspect a fresh snapshot, select the visible model, send `manipulate --operation extract`, then `drag --from-x 0.5 --from-y 0.5 --x 0.7 --y 0.5`, inspect another snapshot, and use Return. Ask uses `ask --question "What supports the backrest on this chair?"`; inspect the returned transcript before claiming an answer was heard or accurate.
