import CryptoKit
import Foundation
import RealityKit
import SpatialCore
import simd

#if os(iOS)
import UIKit
#endif

/// Authored selection volumes in an extracted part's local coordinates, before its scene transform.
public struct ImportedAssetSelectionBox: Codable, Sendable, Equatable {
    public var center: Vec3
    public var size: Vec3

    public init(center: Vec3, size: Vec3) {
        self.center = center
        self.size = size
    }
}

public enum ImportedAssetSelection: Codable, Sendable, Equatable {
    case none
    case boxes([ImportedAssetSelectionBox])

    private enum CodingKeys: String, CodingKey { case kind, boxes }
    private enum Kind: String, Codable { case none, boxes }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        switch try values.decode(Kind.self, forKey: .kind) {
        case .none:
            guard !values.contains(.boxes) else {
                throw DecodingError.dataCorruptedError(forKey: .boxes, in: values,
                    debugDescription: "Disabled selection cannot contain boxes")
            }
            self = .none
        case .boxes:
            self = .boxes(try values.decode([ImportedAssetSelectionBox].self, forKey: .boxes))
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .none: try values.encode(Kind.none, forKey: .kind)
        case .boxes(let boxes):
            try values.encode(Kind.boxes, forKey: .kind)
            try values.encode(boxes, forKey: .boxes)
        }
    }
}

/// App-approved metadata. This is supplied by the host, never by scene/model JSON.
public struct ImportedAssetPart: Codable, Sendable, Equatable {
    public var partID: String
    public var name: String
    public var role: String?
    public var description: String?
    /// Exact, unique authored entity name; nil denotes the hierarchy left after extracting named parts.
    public var entityName: String?
    public var triangleCount: Int
    /// Absent preserves the named-part bounding-box default; explicit policies override it.
    public var selection: ImportedAssetSelection?

    public init(partID: String, name: String, entityName: String?, triangleCount: Int,
                role: String? = nil, description: String? = nil, selection: ImportedAssetSelection? = nil) {
        self.partID = partID
        self.name = name
        self.role = role
        self.description = description
        self.selection = selection
        self.entityName = entityName
        self.triangleCount = triangleCount
    }
}

public struct ImportedAssetDescriptor: Codable, Sendable, Equatable {
    public var assetID: String
    public var name: String?
    public var description: String?
    public var sourceURL: URL
    public var sha256: String
    public var byteCount: Int
    public var uniqueTriangleCount: Int
    public var parts: [ImportedAssetPart]

    public init(assetID: String, sourceURL: URL, sha256: String, byteCount: Int,
                uniqueTriangleCount: Int, parts: [ImportedAssetPart],
                name: String? = nil, description: String? = nil) {
        self.assetID = assetID
        self.name = name
        self.description = description
        self.sourceURL = sourceURL
        self.sha256 = sha256
        self.byteCount = byteCount
        self.uniqueTriangleCount = uniqueTriangleCount
        self.parts = parts
    }
}

public enum ImportedAssetLoadPhase: String, Sendable {
    case checkingCache, downloading, verifying, loadingEntities, preparingParts, installing
}

public struct ImportedAssetLoadReport: Sendable, Equatable {
    public var assetID: String
    public var nodeIDs: [String]
    public var byteCount: Int
    public var expandedTriangleCount: Int
    public var usedFileCache: Bool
    public var usedEntityCache: Bool
    public var loadDurationSeconds: Double
    public var installDurationSeconds: Double
    public var importedEntityCount: Int
    public var importedModelCount: Int
    public var boundsMinimum: Vec3
    public var boundsMaximum: Vec3
}

public enum ImportedAssetError: LocalizedError {
    case invalidDescriptor(String)
    case digestMismatch
    case unexpectedByteCount
    case downloadFailed(Int)
    case missingPart(String)
    case duplicatePart(String)
    case unknownReference(String)
    case budgetExceeded(String)
    case superseded

    public var errorDescription: String? {
        switch self {
        case .invalidDescriptor(let reason): "Invalid imported asset: \(reason)."
        case .digestMismatch: "The downloaded asset does not match its approved SHA-256."
        case .unexpectedByteCount: "The asset does not match its approved byte count."
        case .downloadFailed(let status): "Asset download failed with HTTP \(status)."
        case .missingPart(let name): "The USDZ is missing the approved part \(name)."
        case .duplicatePart(let name): "The USDZ contains an ambiguous part name: \(name)."
        case .unknownReference(let reference): "Imported geometry is not loaded and approved: \(reference)."
        case .budgetExceeded(let resource): "Imported asset exceeds the \(resource) budget."
        case .superseded: "Asset loading was superseded by another scene action."
        }
    }
}

/// Disk verification and networking are isolated from RealityKit's main-actor entity ownership.
actor ImportedAssetFileCache {
    static let shared = ImportedAssetFileCache()

    func file(for descriptor: ImportedAssetDescriptor, directory: URL?,
              progress: @escaping @MainActor (ImportedAssetLoadPhase) -> Void) async throws -> (URL, Bool) {
        let directory = directory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("AstraSpatial/ImportedAssets", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cached = directory.appendingPathComponent(descriptor.sha256).appendingPathExtension("usdz")
        await progress(.checkingCache)
        if FileManager.default.fileExists(atPath: cached.path) {
            do {
                try verify(cached, descriptor: descriptor)
                return (cached, true)
            } catch {
                try FileManager.default.removeItem(at: cached)
            }
        }
        try Task.checkCancellation()
        let temporary: URL
        if descriptor.sourceURL.isFileURL {
            temporary = descriptor.sourceURL
        } else {
            await progress(.downloading)
            let (downloaded, response) = try await URLSession.shared.download(from: descriptor.sourceURL)
            guard let response = response as? HTTPURLResponse, (200...299).contains(response.statusCode) else {
                try? FileManager.default.removeItem(at: downloaded)
                throw ImportedAssetError.downloadFailed((response as? HTTPURLResponse)?.statusCode ?? 0)
            }
            temporary = downloaded
        }
        defer {
            if !descriptor.sourceURL.isFileURL { try? FileManager.default.removeItem(at: temporary) }
        }
        try Task.checkCancellation()
        await progress(.verifying)
        try verify(temporary, descriptor: descriptor)
        // Another load can have populated this digest while the network request was suspended.
        if !FileManager.default.fileExists(atPath: cached.path) {
            try FileManager.default.copyItem(at: temporary, to: cached)
        }
        return (cached, false)
    }

    private func verify(_ url: URL, descriptor: ImportedAssetDescriptor) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attributes[.size] as? NSNumber)?.intValue == descriptor.byteCount else {
            throw ImportedAssetError.unexpectedByteCount
        }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == descriptor.sha256 else { throw ImportedAssetError.digestMismatch }
    }
}

@MainActor
final class ImportedAssetCatalog {
    struct Part {
        var prototype: Entity
        var transform: Transform3D
        var descriptor: ImportedAssetPart
    }

    struct Asset {
        var descriptor: ImportedAssetDescriptor
        var parts: [String: Part]
    }

    private var assets: [String: Asset] = [:]
    private var preparing: [String: ImportedAssetDescriptor] = [:]
    private var pinnedAssetIDs = Set<String>()
    private var stagedReferenceCounts: [String: Int] = [:]
    private var lastUse: [String: UInt64] = [:]
    private var accessSequence: UInt64 = 0
    private var memoryWarningTask: Task<Void, Never>?
    static let maximumExpandedTriangles = 4_000_000
    // These are admission costs, not a claim about resident CPU/GPU bytes.
    static let maximumApprovedBytes = 128 * 1024 * 1024
    static let maximumUniqueTriangles = 2_000_000
    static let preferredAssetCount = 2
    static let maximumAssetCount = 3 // One replacement may stage while the accepted scene remains pinned.

    init() {
        #if os(iOS)
        memoryWarningTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: UIApplication.didReceiveMemoryWarningNotification) {
                guard !Task.isCancelled else { return }
                self?.purgeUnused()
            }
        }
        #endif
    }

    deinit { memoryWarningTask?.cancel() }

    func setPinnedAssetIDs(_ assetIDs: Set<String>) {
        pinnedAssetIDs = assetIDs
        trimUnused()
    }

    /// Dropping app references permits native cleanup; RealityKit may retain internal allocations.
    func purgeUnused() {
        for assetID in assets.keys.filter({ isEvictable($0) }) {
            remove(assetID)
        }
    }

    func trimUnused() {
        while assets.count > Self.preferredAssetCount, let victim = leastRecentlyUsedUnpinned() {
            remove(victim)
        }
    }

    /// A candidate may need an unused cached asset alongside a new download.
    /// Lease all such assets before any suspension can evict one of them.
    func leaseCachedAsset(_ assetID: String) -> Bool {
        guard assets[assetID] != nil else { return false }
        stagedReferenceCounts[assetID, default: 0] += 1
        touch(assetID)
        return true
    }

    func finishPreparing(_ assetID: String) {
        let remaining = stagedReferenceCounts[assetID, default: 0] - 1
        if remaining > 0 { stagedReferenceCounts[assetID] = remaining }
        else { stagedReferenceCounts.removeValue(forKey: assetID) }
        trimUnused()
    }

    private func isEvictable(_ assetID: String) -> Bool {
        !pinnedAssetIDs.contains(assetID) && preparing[assetID] == nil && stagedReferenceCounts[assetID] == nil
    }

    private func touch(_ assetID: String) {
        accessSequence &+= 1
        lastUse[assetID] = accessSequence
    }

    private func remove(_ assetID: String) {
        assets.removeValue(forKey: assetID)
        lastUse.removeValue(forKey: assetID)
    }

    private func leastRecentlyUsedUnpinned() -> String? {
        assets.keys.filter { isEvictable($0) }
            .min { lastUse[$0, default: 0] < lastUse[$1, default: 0] }
    }

    private func fits(_ descriptor: ImportedAssetDescriptor, assetCount: Int) -> Bool {
        let retained = assets.values.map(\.descriptor) + Array(preparing.values)
        return retained.count + 1 <= assetCount
            && retained.reduce(descriptor.byteCount, { $0 + $1.byteCount }) <= Self.maximumApprovedBytes
            && retained.reduce(descriptor.uniqueTriangleCount, { $0 + $1.uniqueTriangleCount }) <= Self.maximumUniqueTriangles
    }

    private func makeRoom(for descriptor: ImportedAssetDescriptor, replacingScene: Bool) throws {
        while !fits(descriptor, assetCount: Self.preferredAssetCount), let victim = leastRecentlyUsedUnpinned() {
            remove(victim)
        }
        let maximumCount = replacingScene ? Self.maximumAssetCount : Self.preferredAssetCount
        guard fits(descriptor, assetCount: maximumCount) else {
            throw ImportedAssetError.budgetExceeded("retained assets and replacement staging")
        }
    }

    func prepare(_ descriptor: ImportedAssetDescriptor, cacheDirectory: URL?,
                 replacingScene: Bool = false,
                 progress: @escaping @MainActor (ImportedAssetLoadPhase) -> Void) async throws -> (Asset, Bool, Bool) {
        try Self.validate(descriptor)
        try Task.checkCancellation()
        if let asset = assets[descriptor.assetID] {
            guard asset.descriptor.sha256 == descriptor.sha256,
                  asset.descriptor.name == descriptor.name,
                  asset.descriptor.description == descriptor.description,
                  asset.descriptor.parts == descriptor.parts,
                  asset.descriptor.byteCount == descriptor.byteCount,
                  asset.descriptor.uniqueTriangleCount == descriptor.uniqueTriangleCount else {
                throw ImportedAssetError.invalidDescriptor("an asset ID cannot be rebound")
            }
            touch(descriptor.assetID)
            if replacingScene { stagedReferenceCounts[descriptor.assetID, default: 0] += 1 }
            return (asset, false, true)
        }
        guard preparing[descriptor.assetID] == nil else {
            throw ImportedAssetError.invalidDescriptor("this asset is already loading")
        }
        try makeRoom(for: descriptor, replacingScene: replacingScene)
        preparing[descriptor.assetID] = descriptor
        defer { preparing.removeValue(forKey: descriptor.assetID) }
        let (url, cached) = try await ImportedAssetFileCache.shared.file(
            for: descriptor, directory: cacheDirectory, progress: progress)
        try Task.checkCancellation()
        progress(.loadingEntities)
        let root = try await Entity(contentsOf: url)
        try Task.checkCancellation()
        progress(.preparingParts)
        var parts: [String: Part] = [:]
        // Resolve every name before detaching anything; overlapping bindings are invalid.
        var named: [(ImportedAssetPart, Entity)] = []
        let entitiesByName = Dictionary(grouping: Self.descendants(root), by: \.name)
        for part in descriptor.parts {
            guard let name = part.entityName else { continue }
            let matches = entitiesByName[name] ?? []
            guard let entity = matches.first else { throw ImportedAssetError.missingPart(name) }
            guard matches.count == 1 else { throw ImportedAssetError.duplicatePart(name) }
            named.append((part, entity))
        }
        let extractedIDs = Set(named.map { ObjectIdentifier($0.1) })
        for (_, entity) in named {
            var parent = entity.parent
            while let candidate = parent {
                guard !extractedIDs.contains(ObjectIdentifier(candidate)) else {
                    throw ImportedAssetError.invalidDescriptor("part bindings overlap")
                }
                parent = candidate.parent
            }
        }
        for (part, entity) in named {
            // RealityKit's USD import conversion is retained in the node transform, including up axis.
            let transform = Transform(matrix: entity.transformMatrix(relativeTo: nil))
            entity.removeFromParent()
            entity.transform = .identity
            Self.removePhysics(entity)
            parts[part.partID] = Part(prototype: entity, transform: transform.sceneTransform, descriptor: part)
        }
        if let remainder = descriptor.parts.first(where: { $0.entityName == nil }) {
            Self.removePhysics(root)
            parts[remainder.partID] = Part(prototype: root, transform: .init(), descriptor: remainder)
        }
        let asset = Asset(descriptor: descriptor, parts: parts)
        assets[descriptor.assetID] = asset
        touch(descriptor.assetID)
        if replacingScene { stagedReferenceCounts[descriptor.assetID, default: 0] += 1 }
        return (asset, cached, false)
    }

    func part(assetID: String, partID: String) throws -> Part {
        guard let part = assets[assetID]?.parts[partID] else {
            throw ImportedAssetError.unknownReference("\(assetID)/\(partID)")
        }
        touch(assetID)
        return part
    }

    static func validate(_ descriptor: ImportedAssetDescriptor) throws {
        guard descriptor.assetID == "sha256:\(descriptor.sha256)",
              descriptor.sha256.count == 64,
              descriptor.sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              descriptor.sourceURL.isFileURL || descriptor.sourceURL.scheme == "https" || descriptor.sourceURL.scheme == "http"
        else { throw ImportedAssetError.invalidDescriptor("identity, digest, or URL") }
        guard (1...64 * 1024 * 1024).contains(descriptor.byteCount),
              (1...1_000_000).contains(descriptor.uniqueTriangleCount),
              (1...64).contains(descriptor.parts.count),
              descriptor.parts.allSatisfy({ (1...Self.maximumExpandedTriangles).contains($0.triangleCount) }),
              descriptor.parts.reduce(0, { $0 + $1.triangleCount }) <= maximumExpandedTriangles
        else { throw ImportedAssetError.budgetExceeded("approved file, mesh, or part count") }
        guard Set(descriptor.parts.map(\.partID)).count == descriptor.parts.count,
              Set(descriptor.parts.compactMap(\.entityName)).count == descriptor.parts.compactMap(\.entityName).count,
              descriptor.parts.filter({ $0.entityName == nil }).count <= 1,
              descriptor.parts.allSatisfy({
                  !$0.partID.isEmpty && $0.partID.utf8.count <= 100 && !$0.name.isEmpty && $0.name.utf8.count <= 256
                    && ($0.role?.utf8.count ?? 0) <= 128 && ($0.description?.utf8.count ?? 0) <= 4096
              }),
              descriptor.name.map({ !$0.isEmpty && $0.utf8.count <= 256 }) ?? true,
              (descriptor.description?.utf8.count ?? 0) <= 4096
        else { throw ImportedAssetError.invalidDescriptor("part identities") }
        var selectionShapeCount = 0
        for part in descriptor.parts {
            switch part.selection {
            case nil: selectionShapeCount += part.entityName == nil ? 0 : 1
            case .none?: break
            case .boxes(let boxes)?:
                guard (1...64).contains(boxes.count), boxes.allSatisfy({ box in
                    [box.center.x, box.center.y, box.center.z].allSatisfy { $0.isFinite && abs($0) <= 1_000 }
                        && [box.size.x, box.size.y, box.size.z].allSatisfy { $0.isFinite && $0 > 0 && $0 <= 1_000 }
                }) else { throw ImportedAssetError.invalidDescriptor("selection boxes") }
                selectionShapeCount += boxes.count
            }
        }
        guard selectionShapeCount <= 128 else { throw ImportedAssetError.budgetExceeded("selection shapes") }
    }

    static func descendants(_ root: Entity) -> [Entity] {
        [root] + root.children.flatMap { descendants($0) }
    }

    private static func removePhysics(_ root: Entity) {
        for entity in descendants(root) {
            entity.components.remove(CollisionComponent.self)
            entity.components.remove(PhysicsBodyComponent.self)
            entity.components.remove(PhysicsMotionComponent.self)
        }
    }
}

private extension Transform {
    var sceneTransform: Transform3D {
        Transform3D(
            translation: Vec3(Double(translation.x), Double(translation.y), Double(translation.z)),
            rotation: Quaternion(Double(rotation.imag.x), Double(rotation.imag.y), Double(rotation.imag.z), Double(rotation.real)),
            scale: Vec3(Double(scale.x), Double(scale.y), Double(scale.z)))
    }
}
