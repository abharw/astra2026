# SpatialApple implementation references

Primary Apple documentation consulted on 2026-09-08:

- [ARView](https://developer.apple.com/documentation/realitykit/arview): scene/anchor ownership, camera modes, hit testing, and ray casting.
- [`ARView.init(frame:cameraMode:automaticallyConfigureSession:)`](https://developer.apple.com/documentation/realitykit/arview/init%28frame%3Acameramode%3Aautomaticallyconfiguresession%3A%29): explicit `.ar` versus `.nonAR` construction and automatic session behavior.
- [Creating screen annotations for objects in an AR experience](https://developer.apple.com/documentation/arkit/creating-screen-annotations-for-objects-in-an-ar-experience): Apple's sample tap-to-world ray-cast flow and the simulator limitation for ARKit.
- [`AnchorEntity.init(world:)`](https://developer.apple.com/documentation/realitykit/anchorentity/init%28world%3A%29-4snw2): world-fixed root placement.
- [Models and meshes](https://developer.apple.com/documentation/realitykit/scene-content-models-and-meshes): built-in primitives and custom mesh construction choices.
- [`MeshDescriptor`](https://developer.apple.com/documentation/realitykit/meshdescriptor): custom positions, normals, and indexed triangles.
- [`MeshResource`](https://developer.apple.com/documentation/realitykit/meshresource): primitive/custom mesh resources and its main-actor isolation.
- [`ModelEntity`](https://developer.apple.com/documentation/realitykit/modelentity): entities composed from a mesh and materials.
- [`Entity.generateCollisionShapes(recursive:)`](https://developer.apple.com/documentation/realitykit/entity/generatecollisionshapes%28recursive%3A%29): generating selection collision shapes from model geometry.
- [`ARView.entities(at:)`](https://developer.apple.com/documentation/realitykit/arview/entities%28at%3A%29): point selection and its `CollisionComponent` requirement.
- [`HasTransform.transform`](https://developer.apple.com/documentation/realitykit/hastransform/transform): local-to-parent transform semantics.
- [`PerspectiveCamera`](https://developer.apple.com/documentation/realitykit/perspectivecamera): explicit virtual camera placement in non-AR mode.
- [`DirectionalLight`](https://developer.apple.com/documentation/realitykit/directionallight): explicit lighting for virtual-camera rendering outside an AR session and `look(at:from:relativeTo:)` aiming.
- [`ARView.Environment.Background`](https://developer.apple.com/documentation/realitykit/arview/environment-swift.struct/background-swift.struct): solid-color backgrounds for the non-AR preview environment.
- [`URLSessionWebSocketTask`](https://developer.apple.com/documentation/foundation/urlsessionwebsockettask): message-oriented WebSocket transport and async send/receive.

The runtime deliberately keeps RealityKit resource construction and scene mutation on the main actor. Pure contract validation remains in `SpatialCore`.
