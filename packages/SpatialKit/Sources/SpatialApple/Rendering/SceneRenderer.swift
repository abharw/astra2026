import CoreGraphics
import Foundation
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
    private let importedAssets = ImportedAssetCatalog()
    private let contentRoot = Entity()
    private var rootAnchor: AnchorEntity
    private var rootTransform = matrix_identity_float4x4
    private var entitiesByNodeID: [String: Entity] = [:]
    private var preparedMeshes: [String: MeshResource] = [:]
    private var preparedMaterials: [String: PhysicallyBasedMaterial] = [:]
    private var importedBounds: [String: BoundingBox] = [:]
    private var importedSelectionOutline: Entity?
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
        importedAssets.setPinnedAssetIDs(initialState.retainedImportedAssetIDs)
    }

    public func attach(to view: ARView) throws {
        guard attachedView !== view else { return }
        rootAnchor.removeFromParent()
        attachedView = view
        view.scene.addAnchor(rootAnchor)
        let prepared = try prepareScene(document)
        installPreparedScene(document, prepared: prepared)
    }

    /// Prepares every required native resource before mutating the accepted entity graph.
    public func loadScene(_ document: SceneDocument) throws {
        let prepared = try prepareScene(document)
        installPreparedScene(document, prepared: prepared)
        importedAssets.setPinnedAssetIDs(Set(document.geometryDefinitions.compactMap {
            if case let .importedAsset(assetID, _) = $0.recipe { return assetID }
            return nil
        }))
    }

    public func loadScene(_ state: SceneState) throws {
        let prepared = try prepareScene(state.document)
        installPreparedScene(state.document, prepared: prepared)
        importedAssets.setPinnedAssetIDs(state.retainedImportedAssetIDs)
    }

    public func setSelection(_ nodeID: String?) {
        guard nodeID != selectedNodeID else { return }
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

    /// Pin every asset referenced by accepted state and undo, not just currently visible nodes.
    func setImportedAssetPins(_ assetIDs: Set<String>) {
        importedAssets.setPinnedAssetIDs(assetIDs)
    }

    func finishImportedAssetPreparation(assetID: String) {
        importedAssets.finishPreparing(assetID)
    }

    func prepareImportedAsset(_ descriptor: ImportedAssetDescriptor, rootNodeID: String, scale: Double,
                              cacheDirectory: URL?, progress: @escaping @MainActor (ImportedAssetLoadPhase) -> Void)
        async throws -> (SceneDocument, ImportedAssetLoadReport) {
        let start = ContinuousClock.now
        let (asset, fileCache, entityCache) = try await importedAssets.prepare(
            descriptor, cacheDirectory: cacheDirectory, replacingScene: true, progress: progress)
        let provenance = Provenance(origin: .imported, factualSupport: .referenceBased,
                                    sourceRefs: ["sha256:\(descriptor.sha256)"])
        var nodes = [SceneNode(nodeId: rootNodeID, transform: .init(scale: Vec3(scale, scale, scale)),
                               semantic: .init(name: descriptor.name ?? "Imported assembly", role: "assembly",
                                               description: descriptor.description), provenance: provenance)]
        var definitions: [GeometryDefinition] = []
        for metadata in descriptor.parts {
            guard let part = asset.parts[metadata.partID] else { throw ImportedAssetError.missingPart(metadata.partID) }
            let recipe = GeometryRecipe.importedAsset(assetID: descriptor.assetID, partID: metadata.partID)
            let geometryID = "imported.\(metadata.partID)"
            definitions.append(GeometryDefinition(geometryId: geometryID,
                contentHash: try canonicalContentHash(for: recipe), recipe: recipe))
            nodes.append(SceneNode(nodeId: metadata.partID, parentId: rootNodeID, geometryId: geometryID,
                                   transform: part.transform, semantic: .init(name: metadata.name,
                                   role: metadata.role ?? "component", description: metadata.description), provenance: provenance))
        }
        let document = SceneDocument(documentId: "document_\(UUID().uuidString.lowercased())",
                                     geometryDefinitions: definitions, nodes: nodes)
        let duration = start.duration(to: .now)
        let report = ImportedAssetLoadReport(assetID: descriptor.assetID, nodeIDs: nodes.map(\.nodeId),
            byteCount: descriptor.byteCount, expandedTriangleCount: descriptor.parts.reduce(0, { $0 + $1.triangleCount }),
            usedFileCache: fileCache, usedEntityCache: entityCache,
            loadDurationSeconds: Double(duration.components.seconds) + Double(duration.components.attoseconds) / 1e18,
            installDurationSeconds: 0,
            importedEntityCount: asset.parts.values.reduce(0) { $0 + ImportedAssetCatalog.descendants($1.prototype).count },
            importedModelCount: asset.parts.values.reduce(0) { count, part in
                count + ImportedAssetCatalog.descendants(part.prototype).filter { $0.components[ModelComponent.self] != nil }.count
            },
            boundsMinimum: Vec3(0, 0, 0), boundsMaximum: Vec3(0, 0, 0))
        return (document, report)
    }

    func prepareScene(_ document: SceneDocument) throws -> PreparedScene {
        var meshes: [String: MeshResource] = [:]
        var importedParts: [String: ImportedAssetCatalog.Part] = [:]
        for definition in document.geometryDefinitions {
            if case let .importedAsset(assetID, partID) = definition.recipe {
                importedParts[definition.geometryId] = try importedAssets.part(assetID: assetID, partID: partID)
            }
        }
        var importedTriangles = 0
        for node in document.nodes {
            guard let geometryID = node.geometryId, let part = importedParts[geometryID] else { continue }
            guard node.materialId == nil else {
                throw ImportedAssetError.invalidDescriptor("imported parts retain authored materials")
            }
            // Include hidden nodes: they still retain native resources and may become visible in a patch.
            importedTriangles += part.descriptor.triangleCount
        }
        guard importedTriangles <= ImportedAssetCatalog.maximumExpandedTriangles else {
            throw ImportedAssetError.budgetExceeded("expanded imported triangles")
        }
        // Reject unapproved references and imported-budget/material failures before allocating procedural resources.
        for definition in document.geometryDefinitions where importedParts[definition.geometryId] == nil {
            meshes[definition.geometryId] = try geometryCompiler.resource(for: definition)
        }
        var materials: [String: PhysicallyBasedMaterial] = [:]
        for definition in document.materials {
            materials[definition.materialId] = materialCompiler.resource(for: definition)
        }
        return PreparedScene(meshes: meshes, materials: materials, importedParts: importedParts)
    }

    /// This synchronous method is the native commit boundary. It has no suspension point.
    func installPreparedScene(_ document: SceneDocument, prepared: PreparedScene) {
        let desiredIDs = Set(document.nodes.map(\.nodeId))
        let removedNodeIDs = entitiesByNodeID.keys.filter { !desiredIDs.contains($0) }
        for nodeID in removedNodeIDs {
            entitiesByNodeID.removeValue(forKey: nodeID)?.removeFromParent()
            importedBounds.removeValue(forKey: nodeID)
        }

        let geometryByID = Dictionary(uniqueKeysWithValues: document.geometryDefinitions.map { ($0.geometryId, $0) })
        let materialByID = Dictionary(uniqueKeysWithValues: document.materials.map { ($0.materialId, $0) })

        let oldNodes = Dictionary(uniqueKeysWithValues: self.document.nodes.map { ($0.nodeId, $0) })
        let oldGeometries = Dictionary(uniqueKeysWithValues: self.document.geometryDefinitions.map { ($0.geometryId, $0) })
        for node in document.nodes {
            let oldNode = oldNodes[node.nodeId]
            let geometryChanged = oldNode?.geometryId != node.geometryId
                || oldNode?.geometryId.flatMap { oldGeometries[$0] } != node.geometryId.flatMap { geometryByID[$0] }
            let entity: Entity
            if let existing = entitiesByNodeID[node.nodeId], !geometryChanged {
                entity = existing
            } else {
                entitiesByNodeID[node.nodeId]?.removeFromParent()
                importedBounds.removeValue(forKey: node.nodeId)
                if let geometryID = node.geometryId, let part = prepared.importedParts[geometryID] {
                    let wrapper = Entity()
                    wrapper.addChild(part.prototype.clone(recursive: true))
                    if part.descriptor.entityName != nil {
                        installImportedBounds(on: wrapper, nodeID: node.nodeId)
                    }
                    entity = wrapper
                } else if let geometryID = node.geometryId, let mesh = prepared.meshes[geometryID] {
                    let model = ModelEntity(mesh: mesh, materials: [nativeMaterial(for: node, prepared: prepared)])
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
            // Transform/visibility-only edits reuse both imported graphs and procedural collision resources.
            if let model = entity as? ModelEntity,
               oldNode?.materialId != node.materialId,
               let geometryID = node.geometryId, let mesh = prepared.meshes[geometryID] {
                model.model = ModelComponent(mesh: mesh, materials: [nativeMaterial(for: node, prepared: prepared)])
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

    /// One box per selectable imported part; no convex hull work on the imported mesh.
    private func installImportedBounds(on wrapper: Entity, nodeID: String) {
        let bounds = wrapper.visualBounds(relativeTo: wrapper)
        let size = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.001))
        let proxy = Entity()
        proxy.name = "astra.imported.bounds"
        proxy.position = bounds.center
        proxy.components.set(CollisionComponent(shapes: [.generateBox(size: size)]))
        wrapper.addChild(proxy)
        importedBounds[nodeID] = bounds
    }

    /// One lazily allocated outline follows selection; its twelve edges share one mesh resource.
    private func updateImportedSelection() {
        guard let nodeID = selectedNodeID,
              let wrapper = entitiesByNodeID[nodeID],
              let bounds = importedBounds[nodeID] else {
            importedSelectionOutline?.isEnabled = false
            return
        }
        let outline = importedSelectionOutline ?? makeImportedSelectionOutline()
        if outline.parent !== wrapper { wrapper.addChild(outline) }
        outline.position = bounds.center
        let size = simd_max(bounds.extents, SIMD3<Float>(repeating: 0.001))
        let thickness: Float = 0.002
        for (index, edge) in outline.children.enumerated() {
            let axis = index / 4
            let a = (axis + 1) % 3
            let b = (axis + 2) % 3
            var edgeSize = SIMD3<Float>(repeating: thickness)
            edgeSize[axis] = size[axis] + thickness
            edge.scale = edgeSize
            var position = SIMD3<Float>.zero
            position[a] = (index % 4 < 2 ? -1 : 1) * size[a] / 2
            position[b] = (index % 2 == 0 ? -1 : 1) * size[b] / 2
            edge.position = position
        }
        outline.isEnabled = true
    }

    private func makeImportedSelectionOutline() -> Entity {
        let outline = Entity()
        outline.name = "astra.imported.selection"
        let mesh = MeshResource.generateBox(size: 1)
        let material = UnlitMaterial(color: .yellow)
        for _ in 0..<12 {
            outline.addChild(ModelEntity(mesh: mesh, materials: [material]))
        }
        importedSelectionOutline = outline
        return outline
    }

    private func applySelectionAppearance() {
        updateImportedSelection()
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
    var importedParts: [String: ImportedAssetCatalog.Part]
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
