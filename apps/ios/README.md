# Astra Spatial Demo iOS app

This is the universal SwiftUI composition root for the spatial conversation demo. It targets iPhone and iPad from iOS 26.0 and consumes the local `SpatialKit` package through the two public products `SpatialCore` and `SpatialApple`.

The view owns adaptive controls and permissions. `SpatialApple` owns the native scene controller and RealityKit surface. The authored rack is available offline; live scene requests and voice use the configured backend. Hand mode runs locally on the existing AR camera session and displays fingertip and stable-target feedback.

## Build

From this directory:

```sh
/opt/homebrew/bin/xcodegen generate
xcodebuild -project AstraSpatialDemo.xcodeproj \
  -scheme AstraSpatialDemo \
  -destination 'platform=iOS Simulator,id=564C0D96-3E0F-491B-8592-910A7DAEECEA' \
  -configuration Debug build
```

For a development device launch, the Debug build reads `ASTRA_BACKEND_URL` and
`ASTRA_SESSION_TOKEN` from the process environment when present. The connection
settings sheet remains available for changing either value at runtime; release
builds use the local URL default and never embed a token.

The simulator renders a clearly labelled non-AR preview. It does not claim camera tracking or real AR. On a supported device the runtime can select the AR camera surface and must still report tracking availability at runtime.

## Apple API references

- [ARView camera mode](https://developer.apple.com/documentation/realitykit/arview/cameramode-swift.enum/ar)
- [RealityKit entity picking](https://developer.apple.com/documentation/realitykit/arview/entity%28at%3A%29)
- [ARKit verifying device support and permission](https://developer.apple.com/documentation/arkit/verifying-device-support-and-user-permission)
- [Vision hand pose request](https://developer.apple.com/documentation/vision/detecthumanhandposerequest)
- [AVAudioSession record permission](https://developer.apple.com/documentation/avfaudio/avaudiosession/requestrecordpermission%28_%3A%29)

Pointing frames, speech-start selection binding, native audio, and the Realtime connection are integrated. Simulator mode explicitly reports that physical hand pointing is unavailable. The same camera/Vision/RealityKit code runs on iPhone and iPad; compact controls adapt to phone viewports.
