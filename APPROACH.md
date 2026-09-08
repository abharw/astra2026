# Building Astra AR together

A sequential log of Arav's direction, Astra's work, and the decisions they reached together. Technical decisions live in [architecture.md](architecture.md); supporting sources live in [RESEARCH.md](RESEARCH.md).

## September 8, 2026

1. **Arav asked Astra to read the hackathon guidelines.** He had the Cerebral Valley OpenAI Hackathon participant guide open in Firefox and asked Astra to scroll through everything, especially the criteria for technical use of Astra.

2. **Arav explained the project.** He described a Jarvis-style AR framework that could generate assets, deconstruct them, and explain them through real-time voice. He proposed starting on iPhone, exploring Quest later, and using a server rack for the first demo. Apart from a starting asset, he wanted the interaction to be unscripted.

3. **Arav asked for research and grilling.** He asked Astra to fan out research agents, think through the framework and stack, use the grilling skill, and maintain a Markdown record of how Astra contributed during development.

4. **Astra read the complete guide and inspected the workspace.** The judging criteria gave equal weight to Astra in development, Astra in the project, live demo, and technicality. Astra checked the empty Git repo, confirmed Xcode was installed, and found the known iPhones offline. It started five research tracks: iPhone AR, Astra/voice, assets and scene operations, Quest portability, and judging critique.

5. **Astra asked Arav to clarify the core experiment.** The questions covered live creation versus rearranging authored parts, the intended user, and Swift versus Unity experience.

6. **Arav made live generation central.** He explained that he wanted to discover how quickly and effectively Astra could create parts in AR. He wanted to try both deconstructing a detailed existing assembly and generating a deconstruction on demand. He chose hardware architecture exploration as the first use case and favored Swift, with no strong existing stack preference.

7. **Astra revised the research.** It added a sixth agent focused on live geometry and expanded the proposal beyond manipulating prebuilt pieces. It investigated model-generated geometry descriptions that native code could turn into new meshes, while distinguishing reference-based parts from illustrative interiors.

8. **Astra asked about visual fidelity.** It proposed a clean, editable CAD-like assembly as a possible initial target.

9. **Arav corrected the priority.** The main experiment was the real-time voice loop with real-time generation. Initial schematics did not need perfect fidelity; the important behavior was generating something helpful on demand from what the person was saying.

10. **Astra centered the proposal on that interaction.** It recommended “speak → generate a helpful AR visual → keep talking → reshape it,” researched Swift/ARKit/RealityKit with separate Astra and Realtime roles, and wrote the initial approach and research documents. Six research investigations were complete; no application or latency benchmark had been built.

11. **Arav asked for a clean architecture and a new home for the repo.** He requested a move into his Developer folder, an explanation of Swift versus cloud responsibilities, and an `architecture.md`. He asked whether a general framework or SDK should make the server rack just one application, and what a judge auditing the code would expect.

12. **Arav clarified this document's purpose.** He wanted a chronological record of his interactions with Astra and how they were building together, beginning with the guidelines, project explanation, and grilling. The implementation plan belongs in the architecture document.

13. **Astra moved the repo and documented the boundaries.** It moved the files and Git metadata to `/Users/aravb/Developer/astra2026`, verified file contents were preserved, and left a compatibility symlink for this active task. It used two additional research/review agents to check SDK/state ownership and Apple's rendering boundaries. It wrote [architecture.md](architecture.md) and rewrote this file as the collaboration log.

14. **Astra reviewed and tightened the proposed design.** An independent review caught that pausing for speech should be separate from cancelling a generation. Astra corrected that behavior, bounded undo to the latest transaction, and added protocol-version compatibility. These are documented design decisions, not yet runtime-tested features.

15. **Arav asked for the literal asset-generation mechanism.** He wanted a much deeper explanation of what Astra writes, what the framework executes, whether assets go into a database, and which design best combines performance, clean architecture, and model capabilities.

16. **Arav explicitly added data formats to that investigation.** He wanted decisions below the level of stack names: how the scene, geometry, transport, and stored assets are actually represented.

17. **Astra ran five additional investigations and expanded the architecture.** The work examined model authoring, current Astra tool APIs, geometry formats, streaming latency, and persistence. Astra separated model source, normalized editable scene data, and native render resources; specified direct structured tools plus an experiment with hosted programmatic authoring; and wrote detailed [pipeline](docs/asset-pipeline.md), [format](docs/data-formats.md), and [storage](docs/storage.md) documents.

18. **Astra used independent review to correct the contracts.** The review refined ordered streaming without per-batch cloud round trips, preserved admission-time intent for delayed output, prevented parallel preparation from overwriting newer scene state, separated installation from durable saving, and required narration to respect actual playback state. These changes are proposals to validate in the first device implementation.

19. **Astra checked the documentation artifacts.** Five JSON examples parsed, the proposed SQL schema executed in an in-memory SQLite database, and local file links and whitespace checks passed. These checks establish example syntax and document consistency; they do not validate a working app, persistence durability, model access, or performance.

20. **Arav challenged the renderer choice and asked about the Neural Engine.** He asked whether Three.js would be quicker than RealityKit and whether Apple's Neural Engine could contribute to the technicality aspect of judging.

21. **Astra separated development speed, rendering speed and local inference.** Two research agents checked current browser/Apple documentation. Astra recommended retaining native iPhone AR, treating Three.js as an optional inspector or later Quest path, and considering local neural perception only when it improves an actual interaction. It documented WebXR versus Quick Look, hardware-profiling requirements, and a possible point-and-ask experiment in the [renderer decision](docs/renderer-choice.md). No renderer comparison or Neural Engine benchmark has run.

22. **Arav chose gesture control as a desired stretch feature.** He wants to explore it if time remains during the hackathon.

23. **Astra added a bounded gesture milestone.** It proposed fingertip hover, pinch-to-select, and a voice follow-up targeting the selected component, with constrained dragging only after selection works. The [gesture plan](docs/gestures.md) records iPhone ergonomics, local execution, input/state ownership, failure handling, and device acceptance checks. Gesture implementation remains pending.

24. **Arav corrected the priority: pointing must be in the demo.** It can follow the first implementation slice, but must not be treated as optional. He mentioned owning an iPad and proposed having someone else hold it while he points. He asked whether the app should work on both devices and whether Neural Engine concerns are necessary.

25. **Astra revised the device and demo strategy.** It researched the shared Apple stack, proposed one universal iPhone/iPad app and a teammate-held iPad demo, and separated required pointing from optional pinch/drag and Neural Engine optimization. A developer-device check found Arav's iPhone 15 Pro available; the iPad model remained unknown. Astra asked about the iPad and the intended pointing interaction.

26. **Arav chose screen-aligned pointing first.** Astra recorded the agreed interaction: line the fingertip up with a highlighted component in the camera view, then speak. It updated the [pointing contract](docs/gestures.md), [device strategy](docs/devices.md), and architecture so full 3D finger-direction tracking is outside the first requirement and pointing remains required demo evidence.

27. **Arav identified the iPad.** He has an iPad Air M4 running iPadOS 26.5. Astra checked Apple's hardware specifications, recorded its 16-core Neural Engine, and selected it as the primary demo target with the iPhone 15 Pro as the second test device. The design uses the shared native stack and requires neither LiDAR nor a separate Neural Engine optimization milestone for screen-aligned pointing. Actual device deployment and performance remain untested.

28. **Arav authorized the initial commit and implementation.** He asked Astra to synchronize the docs, commit them, then use parallel Terra, Luna or Sol agents to build the project. He also asked for a parallel investigation into simulator, laptop-camera and computer-use testing, with the development approach recorded here.

29. **Arav requested source-backed Apple expertise.** He asked Astra to study Apple's RealityKit documentation and useful codebases, keeping references for the implementation. A Luna review checked the current documents; Astra normalized remaining device terminology while preserving the chronological history and added local-secret/build-output exclusions before the initial commit.

Current state: research and architecture documents exist. SDK implementation, a signed phone build, live API calls, generation quality, and latency remain to be tested.

---

Append meaningful interactions in order. Record Arav's corrections as well as Astra's contributions. When implementation begins, link entries to the actual files, commits, tests, or demo evidence; do not describe proposed or untested behavior as completed work.
