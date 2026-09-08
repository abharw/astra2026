import CoreGraphics
import RealityKit
import SpatialCore
import simd

#if os(iOS)
import ARKit
#endif

/// Owns the correspondence between stable `SpatialCore` node IDs and native RealityKit entities.
@MainActor
public final class SceneRenderer {
    public private(set) var document: SceneDocument
    public private(set) var selectedNodeID: String?

    private let geometryCompiler = GeometryCompiler()
    private let materialCompiler = MaterialCompiler()
    private let contentRoot = Entity()
    private var rootAnchor: AnchorEntity
    private var rootTransform = matrix_identity_float4x4
    private var entitiesByNodeID: [String: Entity] = [:]
    private var preparedMeshes: [String: MeshResource] = [:]
    private var preparedMaterials: [String: PhysicallyBasedMaterial] = [:]
    private weak var attachedView: ARView?

    public init(initialDocument: SceneDocument = SceneDocument(documentId: "document_local")) {
        document = initialDocument
        rootAnchor = AnchorEntity(world: matrix_identity_float4x4)
        rootAnchor.name = "astra.scene.root"
        contentRoot.name = "astra.scene.content"
        rootAnchor.addChild(contentRoot)
    }

    public convenience init(initialState: SceneState) {
        self.init(initialDocument: initialState.document)
    }

    public func attach(to view: ARView) throws {
        guard attachedView !== view else { return }
        rootAnchor.removeFromParent()
        attachedView = view
        view.scene.addAnchor(rootAnchor)
        try loadScene(document)
    }

    /// Prepares every required native resource before mutating the accepted entity graph.
    public func loadScene(_ document: SceneDocument) throws {
        let prepared = try prepareScene(document)
        installPreparedScene(document, prepared: prepared)
    }

    public func loadScene(_ state: SceneState) throws {
        try loadScene(state.document)
    }

    public func setSelection(_ nodeID: String?) {
        guard nodeID == nil || entitiesByNodeID[nodeID!] != nil else {
            selectedNodeID = nil
            applySelectionAppearance()
            return
        }
        selectedNodeID = nodeID
        applySelectionAppearance()
    }

    @discardableResult
    public func select(at point: CGPoint, in view: ARView? = nil) -> String? {
        guard let nodeID = nodeID(at: point, in: view) else {
            setSelection(nil)
            return nil
        }
        setSelection(nodeID)
        return nodeID
    }

    public func nodeID(at point: CGPoint, in view: ARView? = nil) -> String? {
        let view = view ?? attachedView
        guard let entity = view?.entity(at: point) else { return nil }
        var current: Entity? = entity
        while let candidate = current {
            if candidate.name.hasPrefix(Self.nodeNamePrefix) {
                return String(candidate.name.dropFirst(Self.nodeNamePrefix.count))
            }
            current = candidate.parent
        }
        return nil
    }

    public func placeRoot(worldTransform: simd_float4x4) {
        rootTransform = worldTransform
        rootAnchor.removeFromParent()
        rootAnchor = AnchorEntity(world: worldTransform)
        rootAnchor.name = "astra.scene.root"
        rootAnchor.addChild(contentRoot)
        attachedView?.scene.addAnchor(rootAnchor)
    }

    #if os(iOS)
    /// Places the scene on the first plane found under a screen-space tap.
    @discardableResult
    public func placeRoot(at point: CGPoint, in view: ARView? = nil) -> Bool {
        let view = view ?? attachedView
        guard let view,
              view.cameraMode == .ar,
              let result = view.raycast(from: point, allowing: .estimatedPlane, alignment: .any).first
        else {
            return false
        }
        placeRoot(worldTransform: result.worldTransform)
        return true
    }
    #endif

    public func entity(for nodeID: String) -> Entity? {
        entitiesByNodeID[nodeID]
    }

    func prepareScene(_ document: SceneDocument) throws -> PreparedScene {
        var meshes: [String: MeshResource] = [:]
        for definition in document.geometryDefinitions {
            meshes[definition.geometryId] = try geometryCompiler.resource(for: definition)
        }
        var materials: [String: PhysicallyBasedMaterial] = [:]
        for definition in document.materials {
            materials[definition.materialId] = materialCompiler.resource(for: definition)
        }
        return PreparedScene(meshes: meshes, materials: materials)
    }

    /// This synchronous method is the native commit boundary. It has no suspension point.
    func installPreparedScene(_ document: SceneDocument, prepared: PreparedScene) {
        let desiredIDs = Set(document.nodes.map(\.nodeId))
        let removedNodeIDs = entitiesByNodeID.keys.filter { !desiredIDs.contains($0) }
        for nodeID in removedNodeIDs {
            entitiesByNodeID.removeValue(forKey: nodeID)?.removeFromParent()
        }

        let geometryByID = Dictionary(uniqueKeysWithValues: document.geometryDefinitions.map { ($0.geometryId, $0) })
        let materialByID = Dictionary(uniqueKeysWithValues: document.materials.map { ($0.materialId, $0) })

        for node in document.nodes {
            let needsModel = node.geometryId != nil
            let existing = entitiesByNodeID[node.nodeId]
            let existingIsModel = existing is ModelEntity
            let entity: Entity
            if let existing, needsModel == existingIsModel {
                entity = existing
            } else {
                existing?.removeFromParent()
                if let geometryID = node.geometryId, let mesh = prepared.meshes[geometryID] {
                    let material = nativeMaterial(for: node, prepared: prepared)
                    let model = ModelEntity(mesh: mesh, materials: [material])
                    model.generateCollisionShapes(recursive: false)
                    entity = model
                } else {
                    entity = Entity()
                }
                entitiesByNodeID[node.nodeId] = entity
            }

            entity.name = Self.nodeNamePrefix + node.nodeId
            entity.transform = node.transform.realityKitTransform
            entity.isEnabled = node.isVisible

            if let model = entity as? ModelEntity,
               let geometryID = node.geometryId,
               let mesh = prepared.meshes[geometryID]
            {
                model.model = ModelComponent(
                    mesh: mesh,
                    materials: [nativeMaterial(for: node, prepared: prepared)]
                )
                model.generateCollisionShapes(recursive: false)
            }
        }

        for node in document.nodes {
            guard let entity = entitiesByNodeID[node.nodeId] else { continue }
            let desiredParent = node.parentId.flatMap { entitiesByNodeID[$0] } ?? contentRoot
            if entity.parent !== desiredParent {
                desiredParent.addChild(entity, preservingWorldTransform: false)
            }
        }

        self.document = document
        preparedMeshes = prepared.meshes
        preparedMaterials = prepared.materials
        geometryCompiler.prune(keeping: Array(geometryByID.values))
        materialCompiler.prune(keeping: Array(materialByID.values))
        if let selectedNodeID, !desiredIDs.contains(selectedNodeID) {
            self.selectedNodeID = nil
        }
        applySelectionAppearance()
    }

    private func nativeMaterial(for node: SceneNode, prepared: PreparedScene) -> PhysicallyBasedMaterial {
        if let materialID = node.materialId, let material = prepared.materials[materialID] {
            return material
        }
        var fallback = PhysicallyBasedMaterial()
        fallback.roughness = 0.72
        return fallback
    }

    private func applySelectionAppearance() {
        for node in document.nodes {
            guard let model = entitiesByNodeID[node.nodeId] as? ModelEntity,
                  let mesh = node.geometryId.flatMap({ preparedMeshes[$0] })
            else { continue }
            let materials: [any RealityKit.Material]
            if node.nodeId == selectedNodeID {
                var highlight = PhysicallyBasedMaterial()
                highlight.baseColor = .init(tint: .yellow)
                highlight.emissiveColor = .init(color: .yellow)
                highlight.emissiveIntensity = 0.22
                highlight.roughness = 0.5
                materials = [highlight]
            } else if let materialID = node.materialId, let material = preparedMaterials[materialID] {
                materials = [material]
            } else {
                var fallback = PhysicallyBasedMaterial()
                fallback.roughness = 0.72
                materials = [fallback]
            }
            model.model = ModelComponent(mesh: mesh, materials: materials)
        }
    }

    private static let nodeNamePrefix = "astra.node."
}

struct PreparedScene {
    var meshes: [String: MeshResource]
    var materials: [String: PhysicallyBasedMaterial]
}

private extension Transform3D {
    var realityKitTransform: Transform {
        Transform(
            scale: scale.simdFloat,
            rotation: simd_quatf(
                ix: Float(rotation.x),
                iy: Float(rotation.y),
                iz: Float(rotation.z),
                r: Float(rotation.w)
            ),
            translation: translation.simdFloat
        )
    }
}

private extension Vec3 {
    var simdFloat: SIMD3<Float> {
        SIMD3(Float(x), Float(y), Float(z))
    }
}
