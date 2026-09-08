#if DEBUG
import Foundation
import RealityKit
import SpatialApple
import SpatialCore
import UIKit

/// A launch-only synthetic fixture. It uses the same scene validation and native
/// renderer as user-authored content and never submits a model or network request.
@MainActor
enum DebugFlowAcceptance {
    static var requestedCount: Int? {
        switch ProcessInfo.processInfo.environment["ASTRA_FLOW_ACCEPTANCE_COUNT"] {
        case "0": 0
        case "1": 1
        case "8": 8
        case "32": 32
        default: nil
        }
    }

    static func documentID(for count: Int) -> String { "debug.flow-acceptance.\(count)" }

    static func makeControllerIfRequested() -> SceneController? {
        guard let count = requestedCount else { return nil }
        do {
            let document = try makeDocument(flowCount: count)
            let state = try SceneState(document: document, sceneId: documentID(for: count))
            let controller = SceneController(initialState: state)
            DiagnosticsLog.shared.record("flow.acceptance.fixture_loaded", component: "app.flow_acceptance", fields: [
                "requestedFlowCount": String(count), "documentId": document.documentId,
                "fixtureKind": "synthetic_non_rack", "factualSupport": "illustrative",
            ])
            return controller
        } catch {
            DiagnosticsLog.shared.record("flow.acceptance.fixture_failed", component: "app.flow_acceptance", level: .error,
                fields: ["requestedFlowCount": String(count), "error": error.localizedDescription])
            return nil
        }
    }

    private static func makeDocument(flowCount: Int) throws -> SceneDocument {
        let provenance = Provenance(origin: .authored, factualSupport: .illustrative,
                                    sourceRefs: ["debug:flow-acceptance-v1"])
        let chamber: GeometryRecipe = .box(size: Vec3(0.14, 0.5, 0.26))
        var geometries = [GeometryDefinition(geometryId: "acceptance.chamber", contentHash: try canonicalContentHash(for: chamber),
                                             recipe: chamber)]
        let colors = [
            SpatialCore.Material(materialId: "acceptance.structure", baseColorLinear: [0.14, 0.2, 0.28, 1], metallic: 0.15, roughness: 0.65),
            SpatialCore.Material(materialId: "acceptance.cyan", baseColorLinear: [0.1, 0.8, 0.95, 1], metallic: 0, roughness: 0.7),
            SpatialCore.Material(materialId: "acceptance.amber", baseColorLinear: [1, 0.55, 0.12, 1], metallic: 0, roughness: 0.7),
            SpatialCore.Material(materialId: "acceptance.violet", baseColorLinear: [0.65, 0.4, 1, 1], metallic: 0, roughness: 0.7),
            SpatialCore.Material(materialId: "acceptance.green", baseColorLinear: [0.2, 0.95, 0.55, 1], metallic: 0, roughness: 0.7),
        ]
        var nodes = [
            SceneNode(nodeId: "acceptance.assembly", transform: Transform3D(rotation: Quaternion(0, sin(0.08), 0, cos(0.08))),
                semantic: NodeSemantic(name: "Illustrative transfer manifold", role: "assembly",
                    description: "Synthetic non-rack fixture for native flow rendering; not a physical simulation."), provenance: provenance),
            SceneNode(nodeId: "acceptance.source", parentId: "acceptance.assembly", geometryId: "acceptance.chamber",
                materialId: "acceptance.structure", transform: Transform3D(translation: Vec3(-0.35, 0.26, 0)),
                semantic: NodeSemantic(name: "Input chamber", role: "component"), provenance: provenance),
            SceneNode(nodeId: "acceptance.target", parentId: "acceptance.assembly", geometryId: "acceptance.chamber",
                materialId: "acceptance.structure", transform: Transform3D(translation: Vec3(0.35, 0.26, 0)),
                semantic: NodeSemantic(name: "Output chamber", role: "component"), provenance: provenance),
        ]
        let flowMaterials = ["acceptance.cyan", "acceptance.amber", "acceptance.violet", "acceptance.green"]
        for index in 0..<flowCount {
            let row = flowCount == 1 ? 3.5 : Double(index % 8)
            let depth = flowCount <= 8 ? 1.5 : Double(index / 8)
            let y = (row - 3.5) * 0.06
            let z = (depth - 1.5) * 0.06
            let flow = FlowRecipe(
                source: FlowAttachment(nodeId: "acceptance.source", localPoint: Vec3(0.07, y, z)),
                target: FlowAttachment(nodeId: "acceptance.target", localPoint: Vec3(-0.07, y, z)),
                routePoints: [Vec3(-0.12, 0.295 + y, 0.06 + z), Vec3(0.12, 0.295 + y, 0.06 + z)],
                direction: .forward, width: 0.0048, label: "Flow \(index + 1)", animated: true)
            let recipe: GeometryRecipe = .flow(flow)
            let geometryID = "acceptance.flow.geometry.\(index + 1)"
            geometries.append(GeometryDefinition(geometryId: geometryID, contentHash: try canonicalContentHash(for: recipe), recipe: recipe))
            nodes.append(SceneNode(nodeId: "acceptance.flow.\(index + 1)", parentId: "acceptance.assembly", geometryId: geometryID,
                materialId: flowMaterials[index % flowMaterials.count],
                semantic: NodeSemantic(name: "Transfer path \(index + 1)", role: "flow",
                    description: "Illustrative connection between the input and output chambers."), provenance: provenance))
        }
        return SceneDocument(documentId: documentID(for: flowCount), geometryDefinitions: geometries, materials: colors, nodes: nodes)
    }
}

/// Bounded diagnostics started by the actual active native surface. No timing
/// value reported here measures GPU work or asserts a successful visual result.
@MainActor
final class DebugFlowAcceptanceSampler {
    private final class Owner {
        weak var sampler: DebugFlowAcceptanceSampler?
        weak var view: ARView?
        init(sampler: DebugFlowAcceptanceSampler, view: ARView) {
            self.sampler = sampler
            self.view = view
        }
    }

    private static var owners: [ObjectIdentifier: Owner] = [:]
    private weak var controller: SceneController?
    private weak var view: ARView?
    private let renderer: SceneRenderer
    private let initialScene: SceneState
    private let requestedFlowCount: Int
    private var task: Task<Void, Never>?
    private var runID = UUID().uuidString.lowercased()
    private var startedUptime: TimeInterval?
    private var sampleIndex = 0
    private var completed = false

    init?(controller: SceneController) {
        guard let count = DebugFlowAcceptance.requestedCount,
              controller.acceptedScene.document.documentId == DebugFlowAcceptance.documentID(for: count) else { return nil }
        self.controller = controller
        self.renderer = controller.renderer
        self.initialScene = controller.acceptedScene
        self.requestedFlowCount = count
    }

    /// Call only after renderer attachment and while the coordinator is active.
    /// Sampling itself waits until this ARView is installed in an active window.
    func start(on view: ARView) {
        guard !completed, isOriginalFixture else { return }
        let rendererID = ObjectIdentifier(renderer)
        if let owner = Self.owners[rendererID], owner.sampler === self, owner.view === view { return }
        if let prior = Self.owners[rendererID], let priorView = prior.view {
            prior.sampler?.stop(from: priorView, reason: "surface_replaced")
        }
        Self.owners = Self.owners.filter { $0.value.sampler != nil && $0.value.view != nil }
        self.view = view
        Self.owners[rendererID] = Owner(sampler: self, view: view)
        runID = UUID().uuidString.lowercased()
        startedUptime = nil
        sampleIndex = 0
        task = Task { [weak self, weak view] in
            guard let self, let view else { return }
            await self.collect(on: view)
        }
    }

    /// An old coordinator can never stop a replacement surface's collection.
    func stop(from view: ARView, reason: String = "view_inactive") {
        guard owns(view) else { return }
        task?.cancel()
        task = nil
        record("flow.acceptance.cancelled", extra: ["reason": reason])
        renderer.setFlowMetricsEnabled(false)
        Self.owners.removeValue(forKey: ObjectIdentifier(renderer))
        self.view = nil
    }

    private func collect(on view: ARView) async {
        do {
            // UIKit may call makeUIView before assigning a window. A finite wait
            // avoids recording an unattached view as a render performance sample.
            for _ in 0..<100 {
                guard owns(view), !Task.isCancelled else { return }
                if view.window != nil, UIApplication.shared.applicationState == .active { break }
                try await Task.sleep(for: .milliseconds(50))
            }
            guard owns(view), !Task.isCancelled else { return }
            guard view.window != nil, UIApplication.shared.applicationState == .active else {
                stop(from: view, reason: "active_surface_unavailable")
                return
            }
            guard isOriginalFixture, renderer.flowMetrics.flowCount == requestedFlowCount else {
                stop(from: view, reason: "fixture_not_installed")
                return
            }
            renderer.setFlowMetricsEnabled(true)
            renderer.resetFlowMetrics()
            startedUptime = ProcessInfo.processInfo.systemUptime
            record("flow.acceptance.started")
            for index in 1...30 {
                try await Task.sleep(for: .seconds(1))
                guard owns(view), !Task.isCancelled else { return }
                guard view.window != nil, UIApplication.shared.applicationState == .active else {
                    stop(from: view, reason: "surface_inactive")
                    return
                }
                guard isOriginalFixture else {
                    stop(from: view, reason: "fixture_changed")
                    return
                }
                guard renderer.flowMetrics.flowCount == requestedFlowCount else {
                    stop(from: view, reason: "fixture_not_installed")
                    return
                }
                sampleIndex = index
                record("flow.acceptance.sample")
            }
            completed = true
            record("flow.acceptance.finished")
            renderer.setFlowMetricsEnabled(false)
            Self.owners.removeValue(forKey: ObjectIdentifier(renderer))
            task = nil
            self.view = nil
        } catch is CancellationError {
            // The owning stop call already emitted its interruption and disabled
            // metrics. It may now belong to a replacement view; do not touch it.
        } catch {
            stop(from: view, reason: "sampling_failed")
        }
    }

    private var isOriginalFixture: Bool {
        guard let scene = controller?.acceptedScene else { return false }
        return scene.sceneId == initialScene.sceneId && scene.revision == initialScene.revision
            && scene.document == initialScene.document
    }

    private func owns(_ view: ARView) -> Bool {
        guard self.view === view, let owner = Self.owners[ObjectIdentifier(renderer)] else { return false }
        return owner.sampler === self && owner.view === view
    }

    private func record(_ event: String, extra: [String: String] = [:]) {
        let metrics = renderer.flowMetrics
        let device = UIDevice.current
        #if targetEnvironment(simulator)
        let surface = "simulator"
        let simulator = true
        #else
        let surface = "physicalAR"
        let simulator = false
        #endif
        var fields = [
            "requestedFlowCount": String(requestedFlowCount), "sampleIndex": String(sampleIndex),
            "elapsedSeconds": String(startedUptime.map { ProcessInfo.processInfo.systemUptime - $0 } ?? 0),
            "durationSeconds": "30", "platform": "iOS", "surface": surface,
            "reduceMotion": String(UIAccessibility.isReduceMotionEnabled), "metricKind": "cpu_and_callback_cadence_not_gpu",
            "flowCount": String(metrics.flowCount), "visibleFlowCount": String(metrics.visibleFlowCount),
            "markerCount": String(metrics.markerCount), "meshCount": String(metrics.meshCount),
            "vertexCount": String(metrics.vertexCount), "triangleCount": String(metrics.triangleCount),
            "meshRebuildCount": String(metrics.meshRebuildCount), "updateCount": String(metrics.updateCount),
            "sampleCount": String(metrics.sampleCount), "meanFrameIntervalMs": String(metrics.meanFrameIntervalMs),
            "p95FrameIntervalMs": String(metrics.p95FrameIntervalMs), "meanMarkerUpdateMs": String(metrics.meanMarkerUpdateMs),
            "p95MarkerUpdateMs": String(metrics.p95MarkerUpdateMs), "maximumMarkerUpdateMs": String(metrics.maximumMarkerUpdateMs),
            "animationEnabled": String(metrics.animationEnabled),
        ]
        if event == "flow.acceptance.started" {
            // DiagnosticsLog has a deliberate 24-field cap. Keep device context
            // on this receipt; later samples join it through the run correlationID.
            for name in ["meshRebuildCount", "updateCount", "sampleCount", "meanFrameIntervalMs",
                         "p95FrameIntervalMs", "meanMarkerUpdateMs", "p95MarkerUpdateMs", "maximumMarkerUpdateMs"] {
                fields.removeValue(forKey: name)
            }
            fields["deviceName"] = device.name
            fields["deviceModel"] = device.model
            fields["osVersion"] = device.systemVersion
            fields["simulator"] = String(simulator)
        }
        fields.merge(extra, uniquingKeysWith: { _, new in new })
        DiagnosticsLog.shared.record(event, component: "app.flow_acceptance", correlationID: runID, fields: fields)
    }
}
#endif
