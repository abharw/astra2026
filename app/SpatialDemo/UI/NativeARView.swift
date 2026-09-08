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
    var isActive: Bool
    @Environment(\.scenePhase) private var scenePhase

    init(
        controller: SceneController,
        pointingEnabled: Binding<Bool>,
        isActive: Bool
    ) {
        self.controller = controller
        self._pointingEnabled = pointingEnabled
        self.isActive = isActive
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
        updateActivity(context.coordinator)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        // SceneController is shared with the runtime view. Updates arrive via
        // its accepted scene and selection events; no duplicate scene state is
        // kept in this composition root.
        updateActivity(context.coordinator)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.dismantle()
    }

    private func updateActivity(_ coordinator: Coordinator) {
        coordinator.updateActivity(
            sessionActive: scenePhase == .active,
            pointingEnabled: pointingEnabled && isActive
        )
    }

    @MainActor
    final class Coordinator: NSObject, ARSessionDelegate {
        private let controller: SceneController
        private weak var view: ARView?
        private var pointingAdapter: ARPointingFrameAdapter?
        private var isPointingEnabled = false
        private var wantsPointing = false
        private var isSessionActive = true
        private var isInterrupted = false
        private var pausedConfiguration: ARConfiguration?

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

        func updateActivity(sessionActive: Bool, pointingEnabled: Bool) {
            wantsPointing = pointingEnabled
            #if !targetEnvironment(simulator)
            if sessionActive != isSessionActive {
                isSessionActive = sessionActive
                if sessionActive {
                    if let pausedConfiguration {
                        // Resume the same configuration without resetting world
                        // tracking or removing the user's placed scene anchors.
                        view?.session.run(pausedConfiguration)
                        self.pausedConfiguration = nil
                    }
                } else {
                    pausedConfiguration = view?.session.configuration
                    view?.session.pause()
                }
            }
            setPointingEnabled(pointingEnabled && sessionActive && !isInterrupted)
            #else
            setPointingEnabled(false)
            #endif
        }

        func dismantle() {
            setPointingEnabled(false)
            view?.session.delegate = nil
            #if !targetEnvironment(simulator)
            view?.session.pause()
            #endif
            view = nil
        }

        private func setPointingEnabled(_ enabled: Bool) {
            guard enabled != isPointingEnabled else { return }
            isPointingEnabled = enabled
            // Fence queued/in-flight results before clearing feedback. A result
            // from the camera's previous lifetime must not resurrect its cursor.
            pointingAdapter?.invalidateViewport()
            pointingAdapter = nil
            controller.stopPointingTracking()
            pointingAdapter = enabled ? controller.makePointingFrameAdapter() : nil
            DiagnosticsLog.shared.record("tracking.activity", component: "pointing", fields: [
                "enabled": String(enabled), "searchFPS": "5", "trackingFPS": "15"
            ])
        }

        nonisolated func session(_ session: ARSession, didUpdate frame: ARFrame) {
            MainActor.assumeIsolated {
                guard let view = self.view, view.window != nil, self.isPointingEnabled,
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

        nonisolated func sessionWasInterrupted(_ session: ARSession) {
            MainActor.assumeIsolated {
                self.isInterrupted = true
                self.setPointingEnabled(false)
            }
        }

        nonisolated func sessionInterruptionEnded(_ session: ARSession) {
            MainActor.assumeIsolated {
                self.isInterrupted = false
                self.updateActivity(
                    sessionActive: self.isSessionActive,
                    pointingEnabled: self.wantsPointing
                )
            }
        }
    }
}
