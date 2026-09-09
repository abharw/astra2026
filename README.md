# Astra(l) Projection

Point, ask, and explore how things work in AR and VR. Built for the Cerebral Valley / OpenAI hackathon.

## Features

- **Reconstruct real objects · VR.** Point at something and say “reconstruct that.” Astra identifies it from the camera image, searches technical references, and generates an approximate model with individually selectable components. The captured camera pose and surface depth help place it against the real-world surface.

- **Reveal detail on demand · AR + VR.** Start with an 18-server rack exterior and reveal its internal teaching groups as you explore. In VR, “show the processors in server 3” loads just that group. The model knows which parts are available before their geometry loads; bundled resources are decoded on demand, shared between instances, and released when unused.

- **Go deeper inside a component · VR.** Ask for more detail inside a generated part to create further selectable subcomponents while preserving the rest of the assembly. The authored rack uses nine approved teaching groups; generated hidden structures remain labeled as inferred unless supported by exact-model references.

- **Make explanations spatial · AR.** Create and edit scenes through voice or text, selecting parts by touch or hand pointing. Add animated flow paths, attached labels, or generated illustrations. Flow annotations follow their connected parts as you move them, and scene edits support Undo.

- **Learn one part at a time · VR.** Guided walkthroughs pull out and highlight each component, explain its function, and wait for speech playback to finish before advancing. The rack also has a native visual demo that opens and separates its internals without waiting for model generation.

- **Manipulate models and return to them · VR.** Grab, resize, explode, and restore assemblies to their original poses. Save models with local spatial anchors and restore them when those anchors are located again.

## How it works

Astra turns conversation—and, in VR, camera images and technical references—into structured components and scene edits. Realtime handles voice. The apps build and render geometry locally using RealityKit for AR and Unity for VR; tracking, manipulation, and rendering stay on the device.

API access: `gpt-6-astra` and `gpt-realtime-2.1`; AR illustrations also use `gpt-image-2.5-flare`.

## Run AR

Requires Node 22+, Python 3, Xcode 26+, iOS/iPadOS 26+, and Doppler configured with `OPENAI_API_KEY` in `backend/dev`. Run from the repository root:

```sh
npm --prefix backend ci
python3 tools/dev-session.py serve
```

Open `app/AR/AstraSpatialDemo.xcodeproj`. Set `CODE_SIGNING_ALLOWED` and `CODE_SIGNING_REQUIRED` to `YES`, choose your team, and run a **Debug** build on your device. Then, in another terminal:

```sh
python3 tools/dev-session.py launch --device "<device name or ID>"
```

Keep the Mac and device on a reachable network. Tap the **cube icon**, place the rack, and ask a question.

## Run VR

Requires Node 22+, Python 3, an OpenAI API key, Unity **6000.3.23f1** with Android Build Support, and a Quest 3/3S with Developer Mode and USB debugging.

Start an HTTPS tunnel to `localhost:8796` in a separate terminal. From the repository root:

```sh
npm --prefix app/VR/spatial-assembly/server ci
python3 app/VR/spatial-assembly/configure.py https://YOUR-TUNNEL-HOST
python3 app/VR/spatial-assembly/server/launch.py
```

Enter the API key when prompted. Open `app/VR/quest/` in Unity and choose **Spatial Assembly → Build Android APK**, then install:

```sh
adb install -r app/VR/spatial-assembly-quest.apk
```

Launch **Spatial Assembly** from Unknown Sources. Keep the bridge and tunnel running.
