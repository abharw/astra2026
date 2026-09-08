# Quest AR testing with live browser casting

September 8, 2026. This records the physical Quest 3 testing session, including failures. Built APKs and code checks are separate from what was actually observed in the headset.

## The wearer and agent tested together

The wearer opened Spatial Assembly on the physical Quest and shared the headset view through Meta Horizon casting in the desktop browser. The wearer handled account login, headset permissions and controller interaction. Codex opened and inspected that casting page, watched successive actual screenshots of the same view, and checked the installed app through USB/adb and Unity logs. Codex could see the controls and generated geometry the wearer was seeing; this was not a simulated headset preview.

The wearer reported “I can’t hear it,” confusing state, a control panel that could not be moved, and later a panel near the floor. Codex used those reports together with the visible cast and device state to diagnose, change code, build, install and relaunch. The user then asked for another reload while the browser cast remained available, and Codex observed the updated Ready panel and a cyan chair assembly.

This is a collaborative wearer-in-the-loop test: the wearer performs embodied actions and reports comfort/audio, while the agent watches the shared visual result and operates the development tools. The agent did not remotely actuate Quest controllers, and seeing an answer transcript is not hearing the headset speakers. Browser snapshots were inspected at specific moments; they are not a claim that every intervening video frame or audio sample was reviewed.

## How we watched and tested

1. Connect and unlock a Developer Mode Quest 3 over USB. Authorize debugging inside the headset. Check `adb devices -l`.
2. Install the paired APK with `adb install -r /path/to/spatial-assembly-quest.apk`. Keep the paired Mac generation bridge and its HTTPS tunnel running.
3. Launch with `adb shell am start -n com.akeil.spatialassembly.quest/com.unity3d.player.UnityPlayerGameActivity`. The activity is UnityPlayerGameActivity, not UnityPlayerActivity.
4. Open [Meta Horizon casting](https://horizon.meta.com/casting/) in the desktop browser. Sign in with the headset account and start casting from the headset. Login and verification are completed by the wearer.
5. Inspect the actual browser video while the wearer points, speaks, moves the panel and inspects generated geometry. DOM text alone does not describe the headset video. Browser screenshots are sampled observations, not continuous visual or audio verification.
6. Use `adb shell cmd wifi status`, targeted Unity logs and `adb shell dumpsys audio` to distinguish network, app and audio-routing problems. `adb exec-out screencap -p` also returned real stereo passthrough images while awake, but sometimes returned an empty image while the headset was not presenting. An empty capture is not proof of a blank app.

A restart uses `adb shell am force-stop com.akeil.spatialassembly.quest` followed by the launch command. This interrupts a current scan or voice session; saved objects use their separate persistence flow.

## Observations and fixes

| Test | Observed outcome | Change or remaining check |
| --- | --- | --- |
| Installation and launch | APK installed; process ran; OpenXR reported visible/focused states. | Launch is verified; it does not prove every interaction. |
| Initial connection | Panel said unable to connect. Quest Wi-Fi was disconnected and Android had no default network. Mac bridge and public health endpoint responded. | Connected headset Wi-Fi and relaunched. Later panel showed Connected and Listening. |
| Voice input / reply text | Headset view displayed Listening and a generated answer transcript. | Confirms visible voice-session activity, not audible playback. |
| Silent replies | Wearer could not hear speech. Speaker output was unmuted at 15/15. Generated Unity scene had no AudioListener. | Added a center-eye AudioListener and build validation requiring exactly one. Updated APK installed. Audible output still requires wearer confirmation. |
| Reconstruction | Live cast showed Ready, a selected partially visible tubular-frame sling chair, a cyan generated model and one saved object. | Confirms a rendered generated object in a physical headset. Fit, scale, part accuracy and leave/return persistence are not established by this single view. |
| Unclear state | Wearer could not tell what was running or what to do. | Added primary state, generation timer, next action, live answer text, microphone activity and dynamic Start/Stop voice and Pull/Return labels. |
| Panel movement | Original control panel could not be moved with controllers. | Added header trigger/pinch drag, grip-over-panel drag, distance adjustment and left thumbstick recenter. Wearer movement acceptance remains open. |
| Panel too low | Wearer reported it near the floor; cast showed controls below the main view. A level-direction recenter change alone did not resolve the reported experience. | Default panel now follows horizontal heading at current eye height, so it updates after tracking settles and as the wearer moves. Grab/release pins it. Recenter resumes following. Final APK installed and launched. The browser cast then showed the complete panel centered in the forward view with “Panel follows you” and Ready. Grab/pin behavior and comfort across movement still require wearer acceptance. |

The panel's generated-object label is a model output, not a verified object identity. The chair's cyan geometry is an approximate component assembly, not an exact scan. The camera views contain people and local screens; raw captures and account data are not included in this repository record.

## Earlier panel acceptance (superseded by controller guide)

- After launch, look down then forward and change seated/standing height. Following controls should return to eye height without remaining on the floor.
- Hold the header with trigger or pinch, or hold right grip while pointing at the panel. Move, release, then move your head: the panel should remain pinned. Click the left thumbstick to resume following.
- Choose Start voice, ask a short question, and confirm both audible speech and captions. Check that Listening, Speaking and Stop voice reflect what is happening. Stop voice must stop microphone capture and playback.
- Point at a specific real object and trigger once. Confirm Reconstructing with elapsed time, then Ready with the selected model. Cancel a separate request and confirm it stops.
- Select a part, pull the object, move it and Return. Compare placement from multiple viewpoints. Repeat for a second object and verify saved restoration after restart and after leaving/reentering the room.

See [Quest setup and controls](../quest/README.md), [phone control experiments](PHONE_COMPUTER_USE.md), and [build journal](BUILD_JOURNAL.md).


## Controller-first revision and independent app-level testing

The wearer subsequently asked for native controller interactions, a panel containing instructions only, explicit trigger referents, deletion, multiple-object testing, and a review of the whole harness. The current controls are listed in [quest/README.md](../quest/README.md). The former panel buttons and panel dragging are superseded.

The optional Quest test link uses a separately paired foreground-only connection. `configure-camera-test.py` writes the ignored Quest `control.json`; build preparation includes the link only when that file exists. The wearer can disable it with left grip + B. The local relay accepts the admin credential separately from the device credential, allows one active device, validates command types, and waits for an actual app acknowledgment. A successful queued question is not a completed answer. `control-phone.py` is shared with Quest despite its historical filename.

Examples from the repository root:

```sh
python3 spatial-assembly/server/control-phone.py state
python3 spatial-assembly/server/control-phone.py snapshot --output /private/local/path/quest-camera.jpg
python3 spatial-assembly/server/control-phone.py tap --x 0.67 --y 0.29 --frame-id FRAME_ID
python3 spatial-assembly/server/control-phone.py manipulate --operation delete --object-id OBJECT_ID
python3 spatial-assembly/server/control-phone.py voice.start
python3 spatial-assembly/server/control-phone.py ask --question 'Explode the selected object'
```

Snapshot/tap uses the exact inspected JPEG and associated camera pose, with a ten-second expiry. Surface depth is measured at command time; it is not a frozen depth image. Use stationary targets and refresh after scene changes. The real passthrough camera excludes virtual geometry and the guide; inspect casting separately for those. The harness calls application methods and does not remotely press physical controllers or establish ergonomic smoothness.

### Actual observations before the final controller build

- The saved chair was deleted through the real application's deletion handler. The device acknowledged success; its saved list retained the speaker and omitted the chair. A restart restored the speaker and the chair remained absent. The browser cast also showed the reduced saved-object state. This verifies deletion and restart persistence for that chair.
- A first attempted whiteboard target was rejected as outside the current camera view. After inspecting a fresh real camera image, a second tap initiated reconstruction. The app completed a model labeled “Large whiteboard with marker holders and cloth”; the cast showed cyan generated geometry. Geometry fit and physical identity remain model-derived and unaccepted.
- During a bridge restart, Codex incorrectly parsed an escaped underscore in the supplied credential, causing authentication failure and broken voice. Codex corrected the parsing, verified authentication, restarted the bridge, and observed Listening, transcript and queued audio state. This was an agent-caused regression, not merely disabled voice. Audible headset playback still needs wearer confirmation.

### Review and fixes

Two independent static reviews covered spec behavior and correctness/conventions. No documented coding-rule violation was found. Concrete findings were fixed: automatic bridge reconnect and controller restore recovery; voice-error shutdown so B can retry; explicit-deletion-only anchor erasure during asynchronous saves; atomic part selection on grab; placement mode separated from extracted state; exact inspected image reuse; disconnect delivery before reconnect; and preserving the held object when another reconstruction finishes. Physical-point state is cleared when selecting generated content. Camera-view failure no longer cancels an unrelated reconstruction.

The Android build passed and installed, and all 21 shared backend tests passed. After installation, Quest system logs reported “a Reprojected OS dialog is currently showing” and blocked app launch. Meta's casting page also showed an unavailable-page error. At that point the final controller revision had no live acceptance: grip movement, placement, voice-triggered explosion, final-build restoration and reconnection, and a second new object still needed testing. No success is claimed from the APK installation alone.

### Current wearer acceptance

1. Dismiss any Quest OS dialog, open Spatial Assembly, and resume browser casting.
2. Confirm the guide is readable and left-stick hide/show works.
3. Trigger a real target, then select a generated part. Ask “explain this” in both cases and check the referent.
4. Grip a generated model, move/release it, then grip/trigger to place. Start a new scan after release. While a scan runs, hold another object and verify scan completion does not change which object is held.
5. Say “explode this” and “assemble it”; verify geometry and audible speech. Stop/restart voice with B.
6. Delete a selected model and restart; verify it stays absent. Retry restoration with left grip + left-stick click if needed.
7. Briefly restart the Mac bridge with the app awake; verify automatic recovery, cancellation of old pending work, and B voice restart.

Raw camera images and private credentials remain outside Git. The repository record preserves observed results and limitations without publishing the room's people or screens.
