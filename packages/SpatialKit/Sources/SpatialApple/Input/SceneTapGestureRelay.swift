#if os(iOS)
import RealityKit
import UIKit

@MainActor
final class SceneTapGestureRelay: NSObject {
    weak var controller: SceneController?
    weak var view: ARView?

    init(controller: SceneController, view: ARView) {
        self.controller = controller
        self.view = view
    }

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
        guard gesture.state == .ended, let controller, let view else { return }
        let point = gesture.location(in: view)
        if controller.select(at: point) == nil {
            controller.setSelection(nil)
            _ = controller.placeScene(at: point)
        }
    }
}
#endif
