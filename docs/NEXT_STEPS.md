# Remaining work

## Highest priority: finish the real-room acceptance check

Run the multirooom procedure in VERIFICATION.md. The completed same-location restart test is narrower than leaving and returning later. Verify two saved places, several objects, exploded/extracted states and visually correct placement from different viewpoints.

## Improve stationary-object alignment

The current one-frame bounds and depth plane are rough. Implement guided multiview capture, separate the target surface from background samples, estimate object orientation and extent, and fit the generated model to those measurements. Keep measured data separate from inferred hidden geometry. This is proposed, not present in the code.

## Follow moving objects

World anchors do not follow objects someone picks up. Evaluate Apple's prepared reference-object tracking on a supported OS, or a separately validated local vision/pose pipeline. iOS 27 support does not remove the need for a suitable reference object. Do not present 2D bounding-box tracking alone as reliable 3D pose tracking.

## Make place recovery scale

Current recovery tries saved maps sequentially for fifteen seconds per candidate. More places increase startup search time. Add a local candidate index and guidance images, verify a match with ARKit, and give users explicit names/management. A long continuous walk currently remains one map; place-boundary detection and geographically indexed anchors are not implemented.

## Strengthen runtime behavior

- Confirm drift, relocalization-loss presentation and recovery across real environments.
- Verify voice after restoring a saved model; the bridge's scene context currently originates from generation in its current session.
- Decide how users remove a saved object/place, with clear deletion semantics.
- Improve reconstruction latency and geometric fidelity without hiding approximation.
- Replace the temporary Mac/tunnel dependency with a deployable authenticated service if product scope requires it.
- Evaluate storage growth, map pruning, backups and optional cross-device sync before broad deployment.

These are follow-up tasks, not claims of current functionality.
