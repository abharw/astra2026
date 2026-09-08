# AR and VR apps

| App | Open | Service |
| --- | --- | --- |
| [AR](AR/README.md) | `AR/AstraSpatialDemo.xcodeproj` in Xcode | Repository-root `backend/` |
| [VR](VR/quest/README.md) | `VR/quest/` in Unity | `VR/spatial-assembly/server/` |

`AR/` contains Arav's iPhone/iPad app. Its framework, assets, backend and tools remain at the repository root.

`VR/` preserves the complete Akeil branch tree, including its Quest project, bridge, assets, documentation, older iOS app and browser prototype. Run commands from that tree's README with `app/VR/` as the working directory. The two apps retain their own protocols and services.

See [the integration record](../docs/ar-vr-integration.md) for source commits, build commands and verification.
