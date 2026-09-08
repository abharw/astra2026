# Spatial Assembly

Native iPhone AR prototype using RealityKit/ARKit, GPT-6 Astra image-to-component generation, and OpenAI Realtime voice tools.

## Use

Move the phone slowly until Tracking ready. Tap a real object to lock the surface, then tap Reconstruct that or enable the microphone and say it. The generated approximation appears at the source location. Tap a component to toggle explode/assemble. Parts lists component descriptions and inferred geometry. Pull out enables dragging, rotation and scaling; Return restores the saved source pose and assembled state.

## Spatial behavior and limits

The selected frame and depth are captured together. LiDAR depth samples establish a surface point and estimate a local normal, with raycast/camera-facing fallbacks. GPT returns the image bounds, estimated dimensions, and component primitives. The app estimates scale and fixes the generated model to a world anchor. Only component-local offsets animate when exploding. The home transform is preserved for Return.

This is a generated geometric approximation from one image, not a segmented mesh scan or accurate CAD reconstruction. Hidden components are inferred and labeled. Surface normal and extent estimates can misalign, especially on curved, glossy, thin or partially occluded objects. It does not track a physical object after someone moves it, and recognition can fail when returning under different lighting or changed surroundings. Realtime handles voice; reconstruction has generation latency (the source-photo API probe took about 45 seconds).

## Run from source

Requires Node.js, Python 3, Xcode, XcodeGen, an AR-capable iPhone, and OpenAI access to gpt-6-astra and gpt-realtime-2.1. LiDAR improves placement but is not required.

1. In server, run `npm ci`.
2. Expose localhost:8796 through an HTTPS tunnel (for example `cloudflared tunnel --url http://127.0.0.1:8796`).
3. At this folder root run `python3 configure.py https://YOUR-TUNNEL-HOST`.
4. Run `python3 server/launch.py` and enter the OpenAI API key at the hidden prompt. The key stays in bridge process memory/environment and is not bundled into the app.
5. Set your signing team in ios/project.yml, run `xcodegen generate --spec ios/project.yml`, open the generated Xcode project, and build to your phone.
6. Keep the Mac bridge and tunnel running. Changing the tunnel URL can be handled in Connection settings; rotating the bridge token requires rebuilding the app.

Selected camera images and enabled microphone audio go to OpenAI. Do not distribute the generated Connection.plist or private configuration; these contain the scoped bridge credential. The downloadable source omits all credentials and captured photos.

## Verification completed

- Physical iPhone build succeeded and updated app installed.
- Previous device run showed live camera tracking and bridge connection.
- Real GPT-6 image probe produced eight components.
- Real Realtime probe returned an explode tool call and audio.
- Seventeen backend schema, research and bridge integration tests passed.
- The physical phone generated and saved a speaker. Precise visual alignment and the full tap/explode/return sequence still need visual acceptance.

## Saved places

Generated objects now accumulate in a place instead of replacing one another. A local ARWorldMap and the full object geometry, original pose, current pose, explode amount and display settings are saved automatically every five seconds when ARKit reports mapped or extending quality. Updates use atomic file replacement, with one file per place. Backgrounding saves the latest object state against the cached map.

On launch or return from the background, the app tries saved maps in recency order for up to fifteen seconds each. Content is restored only after ARKit reports relocalizing followed by normal tracking. If no saved map matches, a new place starts without overwriting previous places. The Your places menu allows retrying a saved map or immediately starting somewhere new. Models restore locally without calling GPT again.

Wait for “Saved on this iPhone” before leaving. Unsaved sessions from earlier app versions cannot be recovered. This is local visual relocalization, not global geographic anchoring or a guarantee of recognition in every environment. A long continuous walk remains one AR map; automatic geographic room boundaries are not implemented. No cloud sync or cross-device restoration is included.

Unit tests cover independent saved places, object-state round trips, malformed transforms, invalid maps and an empty library. Physical return-to-room accuracy must be checked on the actual phone.

## Physical persistence check — September 8, 2026

The updated app generated a six-part wall-mounted speaker and automatically wrote a local saved-room file. After terminating and relaunching the app, the same room was restored and autosaved again. Comparing device files before and after showed the same room ID, object ID, full generated assembly and explode state. Maximum matrix-element difference was 0.0000007 (floating-point rounding). Four XCTest persistence tests passed, and the physical device build and installation succeeded. The Mac phone preview was black, so visual overlay alignment after relocalization was not independently confirmed. This checked reopening in the same location, not departure and return to a different room.

## Reference search and part explanations

Each reconstruction first identifies readable model information, searches the web for technical references, then uses the image and retrieved references to build components. Reference links carry exact/similar labels; undocumented hidden geometry remains inferred. Search failure is explicitly reported and generation can fall back to the image. Custom bounded meshes supplement basic primitives.

Open Parts to inspect sources, select Explain part, or enter a correction and choose Research & rebuild. Rebuilding keeps the original/current poses and object identity. Restored geometry is sent back to the voice bridge as scene context, so it can explain a saved object without regenerating it. Voice can request a fresh camera image for a question about the current view.

Pairing now writes both iPhone and Quest files and preserves the token by default. Use `--rotate` to replace it, then restart the bridge and rebuild clients. The research-enabled iPhone app was built, installed and launched; the new flow still needs physical visual acceptance. See [Quest setup](../quest/README.md).
