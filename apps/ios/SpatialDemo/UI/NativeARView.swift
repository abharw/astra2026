import SwiftUI
import UIKit
@preconcurrency import ARKit
import RealityKit
import SpatialApple

/// The runtime owns AR setup and scene projection. The app only selects the
/// device or simulator surface and forwards the shared scene controller.
struct NativeARView: UIViewRepresentable {
    let controller: SceneController
    @Binding var pointingEnabled: Bool

    init(controller: SceneController, pointingEnabled: Binding<Bool> = .constant(false)) {
        self.controller = controller
        self._pointingEnabled = pointingEnabled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(controller: controller)
    }

    func makeUIView(context: Context) -> UIView {
        let view: ARView
        #if targetEnvironment(simulator)
        view = ARViewFactory.make(.nonARSim, controller: controller)
        #else
        view = ARViewFactory.make(.ar(device: UIDevice.current), controller: controller)
        #endif
        context.coordinator.install(on: view)
        context.coordinator.setPointingEnabled(pointingEnabled)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // SceneController is shared with the runtime view. Updates arrive via
        // its accepted scene and selection events; no duplicate scene state is
        // kept in this composition root.
        context.coordinator.setPointingEnabled(pointingEnabled)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.setPointingEnabled(false)
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        private let controller: SceneController
        private weak var view: ARView?
        private var pointingAdapter: ARPointingFrameAdapter?
        private var isPointingEnabled = false

        init(controller: SceneController) {
            self.controller = controller
        }

        func install(on view: ARView) {
            self.view = view
            // Reuse the ARView-owned session. This does not create a camera or
            // start a competing capture pipeline.
            view.session.delegate = self
            view.session.delegateQueue = .main
        }

        func setPointingEnabled(_ enabled: Bool) {
            guard enabled != isPointingEnabled else { return }
            isPointingEnabled = enabled
            controller.stopPointingTracking()
            pointingAdapter = enabled ? controller.makePointingFrameAdapter() : nil
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                guard let view = self.view, self.isPointingEnabled,
                      let adapter = self.pointingAdapter
                else { return }
                // Camera image orientation follows the active window scene. The
                // view's aspect ratio cannot distinguish landscape directions or
                // upside-down portrait, which would mirror pointing coordinates.
                let orientation = view.window?.windowScene?.effectiveGeometry.interfaceOrientation ?? .portrait
                adapter.submit(
                    frame: frame,
                    interfaceOrientation: orientation,
                    viewportSize: view.bounds.size
                )
            }
        }
    }
}
