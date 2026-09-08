import RealityKit

#if os(macOS)
import AppKit
private typealias PreviewColor = NSColor
#else
import UIKit
private typealias PreviewColor = UIColor
#endif

/// Chooses whether an `ARView` uses the physical camera or a virtual camera.
@MainActor
public enum RuntimeMode {
    case automatic
    case augmentedReality
    case nonARSim

    #if os(iOS)
    case ar(device: UIDevice)
    #endif
}

@MainActor
public enum ARViewFactory {
    public static func make(_ mode: RuntimeMode = .automatic) -> ARView {
        #if os(macOS)
        let view = PreviewARView(frame: .zero)
        configureNonARScene(view)
        return view
        #else
        let cameraMode: ARView.CameraMode

        switch mode {
        case .automatic:
            #if targetEnvironment(simulator) || os(macOS)
            cameraMode = .nonAR
            #else
            cameraMode = .ar
            #endif
        case .augmentedReality:
            #if targetEnvironment(simulator) || os(macOS)
            cameraMode = .nonAR
            #else
            cameraMode = .ar
            #endif
        case .nonARSim:
            cameraMode = .nonAR
        #if os(iOS)
        case .ar:
            #if targetEnvironment(simulator)
            cameraMode = .nonAR
            #else
            cameraMode = .ar
            #endif
        #endif
        }

        let view: ARView
        if cameraMode == .nonAR {
            let preview = PreviewARView(frame: .zero, cameraMode: .nonAR, automaticallyConfigureSession: false)
            configureNonARScene(preview)
            view = preview
        } else {
            view = ARView(frame: .zero, cameraMode: .ar, automaticallyConfigureSession: true)
        }
        return view
        #endif
    }

    public static func make(_ mode: RuntimeMode = .automatic, controller: SceneController) -> ARView {
        let view = make(mode)
        controller.attach(to: view)
        return view
    }

    private static func configureNonARScene(_ view: PreviewARView) {
        view.environment.background = .color(PreviewColor(
            red: 0.075,
            green: 0.08,
            blue: 0.09,
            alpha: 1
        ))

        let sceneCenter: SIMD3<Float> = [0, 0.30, 0]
        let cameraPosition: SIMD3<Float> = [0.90, 0.78, 1.45]
        let cameraAnchor = AnchorEntity(world: [0, 0, 0])
        let camera = view.previewCamera
        cameraAnchor.addChild(camera)
        camera.look(at: sceneCenter, from: cameraPosition, relativeTo: cameraAnchor)
        view.scene.addAnchor(cameraAnchor)

        let lightingAnchor = AnchorEntity(world: [0, 0, 0])
        let key = DirectionalLight()
        key.light.intensity = 1_800
        lightingAnchor.addChild(key)
        key.look(at: sceneCenter, from: [0.55, 0.85, 0.75], relativeTo: lightingAnchor)

        let fill = DirectionalLight()
        fill.light.intensity = 650
        lightingAnchor.addChild(fill)
        fill.look(at: sceneCenter, from: [-0.45, 0.42, 0.55], relativeTo: lightingAnchor)
        view.scene.addAnchor(lightingAnchor)
    }
}
