import Foundation
import SpatialCore

/// A host-authored connection between an immutable representation and its next
/// useful children. It describes one level of an arbitrary asset tree, not an
/// application-specific category or a geometric level of detail.
public struct ImportedAssetDetailTemplate: Codable, Sendable, Equatable {
    public struct Match: Codable, Sendable, Equatable {
        public var assetID: String
        public var partID: String

        public init(assetID: String, partID: String) {
            self.assetID = assetID
            self.partID = partID
        }
    }

    public struct Child: Codable, Sendable, Equatable {
        public var partID: String
        /// Rest pose in the matching node's local coordinates. Import-axis
        /// conversion belongs in the asset compiler/host binding, never the model.
        public var transform: Transform3D
        public var semantic: NodeSemantic
        public var provenance: Provenance

        public init(partID: String, transform: Transform3D, semantic: NodeSemantic, provenance: Provenance) {
            self.partID = partID
            self.transform = transform
            self.semantic = semantic
            self.provenance = provenance
        }
    }

    public var detailId: String
    public var name: String
    public var description: String?
    public var matches: [Match]
    public var assetID: String
    public var children: [Child]

    public init(detailId: String, name: String, description: String? = nil,
                matches: [Match], assetID: String, children: [Child]) {
        self.detailId = detailId
        self.name = name
        self.description = description
        self.matches = matches
        self.assetID = assetID
        self.children = children
    }
}

/// Small, URL-free model context. Target IDs refer to the accepted snapshot;
/// children are available representations, not claims of already installed nodes.
public struct AvailableAssetDetail: Codable, Sendable, Equatable {
    public var detailId: String
    public var targetNodeIds: [String]
    public var name: String
    public var description: String?
    public var assetID: String
    public var byteCount: Int
    public var triangleCount: Int
    public var children: [ImportedAssetDetailTemplate.Child]
}

/// Registration validates metadata without downloading or decoding native meshes.
/// A live request can access only immutable resources supplied by the host.
@MainActor
struct ImportedAssetDetailRegistry {
    private(set) var resources: [String: ImportedAssetDescriptor] = [:]
    private(set) var templates: [ImportedAssetDetailTemplate] = []
    private(set) var cacheDirectory: URL?

    mutating func register(_ additions: [ImportedAssetDetailTemplate],
                           resources descriptors: [ImportedAssetDescriptor], cacheDirectory: URL?) throws {
        var candidate = self
        for descriptor in descriptors {
            try ImportedAssetCatalog.validate(descriptor)
            if let existing = candidate.resources[descriptor.assetID], existing != descriptor {
                throw ImportedAssetError.invalidDescriptor("registered resource identity cannot be rebound")
            }
            candidate.resources[descriptor.assetID] = descriptor
        }
        for template in additions {
            try candidate.validate(template)
            if let existing = candidate.templates.first(where: { $0.detailId == template.detailId }) {
                guard existing == template else {
                    throw ImportedAssetError.invalidDescriptor("registered detail identity cannot be rebound")
                }
            } else {
                candidate.templates.append(template)
            }
        }
        guard candidate.templates.count <= 32, candidate.resources.count <= 32,
              try JSONEncoder().encode(candidate.templates).count <= 128 * 1024 else {
            throw ImportedAssetError.budgetExceeded("registered detail metadata")
        }
        candidate.cacheDirectory = cacheDirectory
        self = candidate
    }

    func available(in document: SceneDocument) -> [AvailableAssetDetail] {
        let geometryByID = Dictionary(uniqueKeysWithValues: document.geometryDefinitions.map { ($0.geometryId, $0.recipe) })
        let installedAssetIDs = Set(document.nodes.compactMap { node -> String? in
            guard let geometryID = node.geometryId,
                  case let .importedAsset(assetID, _) = geometryByID[geometryID] else { return nil }
            return assetID
        })
        let available = templates.compactMap { template -> AvailableAssetDetail? in
            guard let descriptor = resources[template.assetID] else { return nil }
            let targets = document.nodes.compactMap { node -> String? in
                guard let geometryID = node.geometryId,
                      case let .importedAsset(assetID, partID) = geometryByID[geometryID],
                      template.matches.contains(where: { $0.assetID == assetID && $0.partID == partID }) else { return nil }
                return node.nodeId
            }
            // Do not silently truncate eligible targets or publish an invalid wire field.
            guard !targets.isEmpty || installedAssetIDs.contains(template.assetID), targets.count <= 128 else { return nil }
            let childIDs = Set(template.children.map(\.partID))
            return AvailableAssetDetail(detailId: template.detailId, targetNodeIds: targets,
                name: template.name, description: template.description, assetID: template.assetID,
                byteCount: descriptor.byteCount,
                triangleCount: descriptor.parts.filter { childIDs.contains($0.partID) }.reduce(0) { $0 + $1.triangleCount },
                children: template.children)
        }
        guard let bytes = try? JSONEncoder().encode(available), bytes.count <= 128 * 1024 else { return [] }
        return available
    }

    private func validate(_ template: ImportedAssetDetailTemplate) throws {
        guard !template.detailId.isEmpty, template.detailId.utf8.count <= 128,
              !template.name.isEmpty, template.name.utf8.count <= 256,
              template.description.map({ !$0.isEmpty }) ?? true,
              (template.description?.utf8.count ?? 0) <= 2048,
              (1...128).contains(template.matches.count), (1...32).contains(template.children.count),
              Set(template.children.map(\.partID)).count == template.children.count,
              let descriptor = resources[template.assetID] else {
            throw ImportedAssetError.invalidDescriptor("detail template identity, resource, or child count")
        }
        let approvedParts = Set(descriptor.parts.map(\.partID))
        guard template.children.allSatisfy({ approvedParts.contains($0.partID) }),
              template.matches.allSatisfy({ !$0.assetID.isEmpty && $0.assetID.utf8.count <= 128 && !$0.partID.isEmpty && $0.partID.utf8.count <= 100 }) else {
            throw ImportedAssetError.invalidDescriptor("detail template references unapproved children")
        }
        guard template.children.allSatisfy({ child in
            (child.semantic.role?.utf8.count ?? 0) <= 256
                && (child.semantic.description?.utf8.count ?? 0) <= 2048
                && (child.semantic.role.map({ !$0.isEmpty }) ?? true)
                && (child.semantic.description.map({ !$0.isEmpty }) ?? true)
                && child.provenance.sourceRefs.count <= 16
                && child.provenance.sourceRefs.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 1024 })
        }) else { throw ImportedAssetError.budgetExceeded("detail child metadata") }
        let selectedParts = Set(template.children.map(\.partID))
        guard descriptor.parts.filter({ selectedParts.contains($0.partID) }).reduce(0, { $0 + $1.triangleCount }) <= 2_000_000 else {
            throw ImportedAssetError.budgetExceeded("advertised detail triangles")
        }
        // Reuse scene numeric, semantic, identifier, provenance and geometry
        // validation so metadata cannot advertise a pose the device would reject.
        let definitions = try template.children.map { child in
            let recipe = GeometryRecipe.importedAsset(assetID: template.assetID, partID: child.partID)
            return GeometryDefinition(geometryId: child.partID, contentHash: try canonicalContentHash(for: recipe), recipe: recipe)
        }
        let nodes = template.children.map { child in
            SceneNode(nodeId: child.partID, geometryId: child.partID, transform: child.transform,
                      semantic: child.semantic, provenance: child.provenance)
        }
        try SceneValidator().validate(SceneDocument(documentId: "detail.validation", geometryDefinitions: definitions, nodes: nodes))
    }
}
