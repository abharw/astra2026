# Astra Spatial

Point, ask, and explore how things work in AR and VR. Built for the Cerebral Valley / OpenAI hackathon. Astra generates scenes, Realtime handles voice, and RealityKit/Unity render locally.

## Features

- **Shared rack:** explore 18 servers and load nine internal teaching groups on demand.
- **AR · iPhone/iPad:** create and edit 3D scenes with voice or text; select parts by touch or hand pointing.
- **AR explanations:** animated flow annotations, generated illustrations, and Undo.
- **VR · Quest:** grab, resize, explode, and inspect components with guided voice walkthroughs.
- **VR reconstruction:** turn camera captures and technical references into approximate editable models; save and restore anchored objects.

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
