# Astro-inspired girl avatar: implementation research

Checked 2026-09-10. This note distinguishes source documentation from proposed implementation. Research did not install software, acquire third-party models, exercise the generated asset, connect a paid voice API, or initiate a FaceTime call.

## Character reference and design decision

Tezuka Productions identifies Atom's pointed hair as an intentional signature and describes his conception as combining boyish and girlish characteristics. That supports retaining a recognizable pointed silhouette when interpreting the user's requested girl version. [Official Atom character entry](https://tezukaosamu.net/en/character/25.html)

Uran is already a girl robot in the original character family: the Japanese official entry identifies her as Atom's robot sister and describes her as spirited, kind, and caring toward her brother. The entry supplies canonical illustrations. She is useful lineage context; the new asset should be described as an authored Astro-inspired girl rather than an official Uran model. [Official Uran character entry](https://tezukaosamu.net/jp/character/84.html)

**Proposed art direction:** simple chibi proportions, large clear eyes, black pointed bob, red boots, a retro robot outfit, and a friendly expression. Keep hair points, eye whites, mouth opening, and eyebrows legible in a small talking-head crop. This is our design choice, not a claim that the exact outfit or bob is canonical.

The user-requested search for **“Astro Boy Blender”** found first-person production examples:

- Mohamed Abd Elsalam's project, with typography credited to Ali Abd Elhadi, describes an Astro Boy reinterpretation made from scratch in Blender and includes clay renders and process images. Useful for the relationship between simple character proportions and polished material presentation; it does not establish a realtime facial rig. [ASTRO BOY, Behance](https://www.behance.net/gallery/223931203/ASTRO-BOY)
- The creator of *Billiken Mighty Atom (Blender)* describes a basic toy body with a more complex head, built around a robot in their personal collection. Useful precedent for concentrating geometry/detail on the face. The post establishes the author's Blender process, not a downloadable animation-ready asset. [Creator's production notes](https://tintoyrobots.com/mighty-atom/)

Neither model was downloaded or reused.

## Blender and portable animation

Blender calls shape keys morph targets or blend shapes. Relative keys blend vertex offsets against a reference, normally `Basis`; several keys combine additively. Topology should be stable before facial keys are authored because each key stores positions for the mesh's vertices. [Blender 4.5 LTS shape-key introduction](https://docs.blender.org/manual/id/4.5/animation/shape_keys/introduction.html)

**Implementation requirements derived from that behavior:**

- Keep a neutral `Basis`, use simple relative facial keys, and preserve an editable `.blend` alongside the delivery `.glb`.
- Expose separately named controls for blinking, brows, smile/frown, and mouth poses. Map UI expressions to these controls instead of baking every expression into unrelated geometry.
- Make the mouth interior visible when open. A changing dark surface alone can read as a sticker rather than an opening.
- Test combined controls, especially smile plus speech and blink plus surprise. Additive deltas can create lip clipping or exaggerated deformation.
- Preserve the head/body skeleton for pose control while driving facial morph weights independently in the web renderer.

Blender's glTF exporter documents object transforms, bone poses, and shape-key values as supported animation. It also documents sampling bone-driven shape keys only when their mesh is a direct child of the driving armature. This is a baking path, not an executable Blender driver system inside GLB. [Blender glTF manual, animations](https://docs.blender.org/manual/en/3.6/addons/import_export/scene_gltf2.html#animations)

**Portable-control decision:** store facial shapes as exported morph targets and implement live mappings/smoothing in the renderer. Keep any Blender drivers as authoring conveniences. For preauthored motion, sample/bake supported channels and inspect the exported animation. The cited glTF manual is version 3.6; exporter options must be checked against the installed Blender version. Do not infer export correctness from a successful Blender render.

## Voice amplitude versus visemes

Web Audio's `AnalyserNode.getFloatTimeDomainData()` provides waveform samples. A local renderer can calculate RMS amplitude from them and smoothly map level to mouth opening. This is a proposed inexpensive fallback; amplitude alone does not identify phonemes or determine the correct consonant mouth pose. [W3C Web Audio specification](https://www.w3.org/TR/webaudio-1.0/#dom-analysernode-getfloattimedomaindata)

For more accurate speech movement, accept timestamped viseme events. Microsoft's Speech documentation defines visemes as visual speech poses, offers 22 IDs, and provides audio-relative offsets in 100 ns ticks; availability varies by voice/locale/output format. It is an example of a provider contract, not a required vendor or an integration completed here. [Microsoft speech-viseme documentation](https://learn.microsoft.com/en-us/azure/cognitive-services/speech-service/how-to-speech-synthesis-viseme)

**Control contract recommendation:** accept clamped morph weights, expression presets, a reset/neutral command, audio playback with amplitude analysis, and optional `{timeMs, viseme}` events. Schedule events against actual audio playback time, rather than network arrival time. Prefer speech movement from the outgoing voice audio so the avatar does not animate from the other caller's voice. Label amplitude mode “audio reactive”; reserve “viseme lip sync” for actual timed speech-pose input.

## FaceTime delivery and acceptance boundary

Apple documents choosing camera, microphone, and output devices separately in FaceTime's **Video** menu. [Apple FaceTime device selection](https://support.apple.com/en-sg/guide/facetime/fctm26739220/mac)

OBS documents its modern virtual camera as compatible with Mac applications when using OBS 30+ on macOS 13+. It documents extension approval through Privacy & Security on macOS 13–14, or General → Login Items & Extensions → Camera Extensions on macOS 15+. These are vendor compatibility statements, not evidence about this particular machine. [OBS virtual-camera troubleshooting](https://obsproject.com/kb/virtual-camera-troubleshooting)

**Proposed route:** GLB → local realtime stage → OBS capture → OBS Virtual Camera → FaceTime camera selection. Use a clean stage without editing controls. Treat voice audio routing as a separate step because selecting a camera does not configure FaceTime's microphone.

The implementation should report each evidence level separately: asset exported; GLB loaded; each expression/mouth target visibly moved; audio-reactive or timed-viseme playback verified; OBS stage rendered; FaceTime selected the virtual camera; remote participant saw and heard synchronized output. The last step requires an authorized real call. A browser preview alone proves none of the final FaceTime steps.
