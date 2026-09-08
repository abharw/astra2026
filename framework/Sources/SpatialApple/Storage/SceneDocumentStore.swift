import Foundation
import SQLite3
import SpatialCore

/// The durable semantic checkpoint for one saved document.
///
/// `sourceSceneId`, `sourceRevision`, and `sourceIntentEpoch` describe the live
/// scene from which the JSON was captured. They are provenance only: a reopen
/// deliberately creates a different live scene identity.
public struct SavedCheckpoint: Sendable, Equatable, Codable {
    public let documentId: String
    public let checkpointVersion: UInt64
    public let sourceSceneId: String
    public let sourceRevision: UInt64
    public let sourceIntentEpoch: UInt64
    public let savedAt: Date

    public init(
        documentId: String,
        checkpointVersion: UInt64,
        sourceSceneId: String,
        sourceRevision: UInt64,
        sourceIntentEpoch: UInt64,
        savedAt: Date
    ) {
        self.documentId = documentId
        self.checkpointVersion = checkpointVersion
        self.sourceSceneId = sourceSceneId
        self.sourceRevision = sourceRevision
        self.sourceIntentEpoch = sourceIntentEpoch
        self.savedAt = savedAt
    }
}

/// A checkpoint reconstructed into a new live runtime session.
///
/// The storage component restores only semantic source. RealityKit entities,
/// pending generation jobs, GPU resources, and camera/animation frames are not
/// part of this value and must be rebuilt by the runtime.
public struct LoadedSceneDocument: Sendable, Equatable {
    public let document: SceneDocument
    public let checkpoint: SavedCheckpoint
    public let sceneId: String
    public let revision: UInt64
    public let intentEpoch: UInt64

    public init(
        document: SceneDocument,
        checkpoint: SavedCheckpoint,
        sceneId: String,
        revision: UInt64 = 0,
        intentEpoch: UInt64 = 0
    ) {
        self.document = document
        self.checkpoint = checkpoint
        self.sceneId = sceneId
        self.revision = revision
        self.intentEpoch = intentEpoch
    }
}

public enum SceneDocumentStoreError: Error, Sendable, Equatable, LocalizedError {
    case invalidDocument(String)
    case missingDocument(String)
    case malformedCheckpoint(String)
    case staleSave(documentId: String, sourceSceneId: String)
    case unknownLiveScene(documentId: String, sourceSceneId: String)
    case sqlite(code: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .invalidDocument(reason):
            "The scene document is not saveable: \(reason)"
        case let .missingDocument(documentId):
            "No saved scene document exists for \(documentId)."
        case let .malformedCheckpoint(reason):
            "The saved scene checkpoint is malformed: \(reason)"
        case let .staleSave(documentId, sourceSceneId):
            "The save for document \(documentId), scene \(sourceSceneId) is older than the current checkpoint."
        case let .unknownLiveScene(documentId, sourceSceneId):
            "Scene \(sourceSceneId) is not the active reopened scene for document \(documentId)."
        case let .sqlite(code, message):
            "SQLite error \(code): \(message)"
        }
    }
}

/// Serializes complete semantic source checkpoints into a local SQLite database.
///
/// This actor is intentionally not main-actor isolated. Its synchronous SQLite
/// work is confined to the actor, while callers keep live RealityKit installation
/// and interaction on their own main-actor boundary.
public actor SceneDocumentStore {
    public let directoryURL: URL

    private var database: SQLiteDatabase?
    private var activeSceneIDs: [String: String] = [:]

    public init(directoryURL: URL) {
        self.directoryURL = directoryURL
    }

    /// Saves a complete semantic snapshot. A newer snapshot from the same live
    /// scene supersedes an older one; reopening first establishes a new scene ID.
    public func save(
        document: SceneDocument,
        sceneId: String,
        revision: UInt64,
        intentEpoch: UInt64
    ) throws -> SavedCheckpoint {
        try validate(document: document, sceneId: sceneId)
        let encodedDocument = try encodedCheckpointDocument(document)
        let database = try openDatabaseIfNeeded()

        return try database.transaction {
            let existing = try database.documentMetadata(documentId: document.documentId)
            if let existing {
                // This is persisted rather than actor-local: another process or
                // store actor may have reopened the document after this actor last
                // saw it. Only the admitted live session may advance a checkpoint.
                guard existing.activeSceneId == sceneId else {
                    throw SceneDocumentStoreError.unknownLiveScene(
                        documentId: document.documentId,
                        sourceSceneId: sceneId
                    )
                }
                if let activeSceneId = activeSceneIDs[document.documentId], activeSceneId != sceneId {
                    throw SceneDocumentStoreError.unknownLiveScene(
                        documentId: document.documentId,
                        sourceSceneId: sceneId
                    )
                }

                if existing.sourceSceneId == sceneId {
                    if revision < existing.sourceRevision {
                        throw SceneDocumentStoreError.staleSave(
                            documentId: document.documentId,
                            sourceSceneId: sceneId
                        )
                    }
                    if revision == existing.sourceRevision,
                       intentEpoch == existing.checkpoint.sourceIntentEpoch {
                        return existing.checkpoint
                    }
                }
            } else {
                activeSceneIDs[document.documentId] = sceneId
            }

            let checkpointVersion = try nextCheckpointVersion(after: existing?.checkpointVersion)
            let savedAt = durableTimestamp()
            let checkpoint = SavedCheckpoint(
                documentId: document.documentId,
                checkpointVersion: checkpointVersion,
                sourceSceneId: sceneId,
                sourceRevision: revision,
                sourceIntentEpoch: intentEpoch,
                savedAt: savedAt
            )
            try database.upsert(document: document, json: encodedDocument, checkpoint: checkpoint)
            return checkpoint
        }
    }

    /// Loads semantic source and mints a new live session. Its revision and epoch
    /// reset to zero so old requests cannot be accepted by the new runtime.
    public func load(documentId: String) throws -> LoadedSceneDocument {
        guard !documentId.isEmpty else {
            throw SceneDocumentStoreError.missingDocument(documentId)
        }

        let newSceneId = UUID().uuidString.lowercased()
        let database = try openDatabaseIfNeeded()
        let (row, document) = try database.transaction {
            guard let row = try database.documentRow(documentId: documentId) else {
                throw SceneDocumentStoreError.missingDocument(documentId)
            }

            let document: SceneDocument
            do {
                document = try JSONDecoder().decode(SceneDocument.self, from: row.json)
            } catch {
                throw SceneDocumentStoreError.malformedCheckpoint("scene JSON cannot be decoded (\(error.localizedDescription))")
            }
            guard document.documentId == row.checkpoint.documentId else {
                throw SceneDocumentStoreError.malformedCheckpoint("document ID does not match its metadata")
            }
            guard document.schemaVersion == row.schemaVersion,
                  document.geometrySemanticsVersion == row.geometrySemanticsVersion else {
                throw SceneDocumentStoreError.malformedCheckpoint("schema metadata does not match scene JSON")
            }
            try validate(document: document, sceneId: row.checkpoint.sourceSceneId)
            try database.admit(sceneId: newSceneId, for: documentId)
            return (row, document)
        }

        activeSceneIDs[documentId] = newSceneId
        return LoadedSceneDocument(
            document: document,
            checkpoint: row.checkpoint,
            sceneId: newSceneId
        )
    }

    /// Lists persisted metadata without decoding every source JSON checkpoint.
    public func list() throws -> [SavedCheckpoint] {
        try openDatabaseIfNeeded().allMetadata()
    }

    private func openDatabaseIfNeeded() throws -> SQLiteDatabase {
        if let database {
            return database
        }

        try FileManager.default.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        let database = try SQLiteDatabase(url: directoryURL.appending(path: "scenes.sqlite"))
        try database.configure()
        self.database = database
        return database
    }

    private func encodedCheckpointDocument(_ document: SceneDocument) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        do {
            let data = try encoder.encode(document)
            // Re-decode the exact bytes written to SQLite, rather than trusting an
            // in-memory Swift object to stand in for a durable JSON checkpoint.
            _ = try JSONDecoder().decode(SceneDocument.self, from: data)
            return data
        } catch {
            throw SceneDocumentStoreError.invalidDocument("it cannot be encoded as JSON (\(error.localizedDescription))")
        }
    }

    private func validate(document: SceneDocument, sceneId: String) throws {
        guard !document.documentId.isEmpty else {
            throw SceneDocumentStoreError.invalidDocument("documentId is empty")
        }
        guard !sceneId.isEmpty else {
            throw SceneDocumentStoreError.invalidDocument("sceneId is empty")
        }
        guard document.schemaVersion == 1, document.geometrySemanticsVersion == 1 else {
            throw SceneDocumentStoreError.invalidDocument("unsupported schema or geometry semantics version")
        }

        let geometryIDs = Set(document.geometryDefinitions.map(\.geometryId))
        guard geometryIDs.count == document.geometryDefinitions.count else {
            throw SceneDocumentStoreError.invalidDocument("geometry IDs are not unique")
        }
        let materialIDs = Set(document.materials.map(\.materialId))
        guard materialIDs.count == document.materials.count else {
            throw SceneDocumentStoreError.invalidDocument("material IDs are not unique")
        }
        let nodeIDs = Set(document.nodes.map(\.nodeId))
        guard nodeIDs.count == document.nodes.count else {
            throw SceneDocumentStoreError.invalidDocument("node IDs are not unique")
        }

        for node in document.nodes {
            guard node.parentId.map(nodeIDs.contains) ?? true else {
                throw SceneDocumentStoreError.invalidDocument("node \(node.nodeId) references a missing parent")
            }
            guard node.geometryId.map(geometryIDs.contains) ?? true else {
                throw SceneDocumentStoreError.invalidDocument("node \(node.nodeId) references missing geometry")
            }
            guard node.materialId.map(materialIDs.contains) ?? true else {
                throw SceneDocumentStoreError.invalidDocument("node \(node.nodeId) references a missing material")
            }
        }
        for relationship in document.relationships {
            guard nodeIDs.contains(relationship.sourceNodeId), nodeIDs.contains(relationship.targetNodeId) else {
                throw SceneDocumentStoreError.invalidDocument("relationship \(relationship.relationshipId) references a missing node")
            }
        }

        // SpatialCore is the normative semantic validator. Constructing a
        // throwaway state validates budgets, geometry recipes, finite values,
        // containment, and references before this actor writes the checkpoint.
        do {
            _ = try SceneState(document: document, sceneId: sceneId)
        } catch {
            throw SceneDocumentStoreError.invalidDocument(String(describing: error))
        }
    }

    private func nextCheckpointVersion(after current: UInt64?) throws -> UInt64 {
        guard let current else { return 1 }
        guard current < UInt64.max else {
            throw SceneDocumentStoreError.invalidDocument("checkpoint version is exhausted")
        }
        return current + 1
    }

    /// SQLite stores the checkpoint timestamp as a binary `REAL`. Normalize the
    /// receipt to millisecond precision first, so callers receive the exact value
    /// that list/load will reconstruct from the durable database row.
    private func durableTimestamp() -> Date {
        let milliseconds = Int64((Date().timeIntervalSince1970 * 1_000).rounded(.towardZero))
        return Date(timeIntervalSince1970: Double(milliseconds) / 1_000)
    }
}

private struct StoredDocumentRow {
    let json: Data
    let checkpoint: SavedCheckpoint
    let schemaVersion: Int
    let geometrySemanticsVersion: Int
}

private struct StoredDocumentMetadata {
    let checkpoint: SavedCheckpoint
    let activeSceneId: String

    var sourceSceneId: String { checkpoint.sourceSceneId }
    var sourceRevision: UInt64 { checkpoint.sourceRevision }
    var checkpointVersion: UInt64 { checkpoint.checkpointVersion }
}

/// SQLite's atomic transaction is the persistence boundary for source JSON and
/// its checkpoint metadata. See https://www.sqlite.org/atomiccommit.html.
private final class SQLiteDatabase: @unchecked Sendable {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(
            url.path,
            &opened,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard result == SQLITE_OK, let opened else {
            let message = opened.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open database"
            sqlite3_close(opened)
            throw SceneDocumentStoreError.sqlite(code: result, message: message)
        }
        handle = opened
    }

    deinit {
        if let handle {
            sqlite3_close(handle)
        }
    }

    func configure() throws {
        // WAL + FULL match the initial device-local durability policy. See
        // https://www.sqlite.org/wal.html and https://www.sqlite.org/pragma.html#pragma_synchronous.
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        try execute("PRAGMA synchronous = FULL")
        try execute(
            """
            CREATE TABLE IF NOT EXISTS documents (
                document_id TEXT PRIMARY KEY NOT NULL,
                schema_version INTEGER NOT NULL,
                geometry_semantics_version INTEGER NOT NULL,
                checkpoint_version TEXT NOT NULL,
                source_scene_id TEXT NOT NULL,
                active_scene_id TEXT NOT NULL,
                source_revision TEXT NOT NULL,
                source_intent_epoch TEXT NOT NULL,
                scene_json BLOB NOT NULL,
                saved_at REAL NOT NULL
            )
            """
        )
    }

    func transaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE TRANSACTION")
        do {
            let value = try body()
            try execute("COMMIT")
            return value
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    func upsert(document: SceneDocument, json: Data, checkpoint: SavedCheckpoint) throws {
        let statement = try prepare(
            """
            INSERT INTO documents (
                document_id, schema_version, geometry_semantics_version, checkpoint_version,
                source_scene_id, active_scene_id, source_revision, source_intent_epoch, scene_json, saved_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(document_id) DO UPDATE SET
                schema_version = excluded.schema_version,
                geometry_semantics_version = excluded.geometry_semantics_version,
                checkpoint_version = excluded.checkpoint_version,
                source_scene_id = excluded.source_scene_id,
                active_scene_id = excluded.active_scene_id,
                source_revision = excluded.source_revision,
                source_intent_epoch = excluded.source_intent_epoch,
                scene_json = excluded.scene_json,
                saved_at = excluded.saved_at
            """
        )
        defer { sqlite3_finalize(statement) }

        try bind(document.documentId, at: 1, in: statement)
        try bind(Int64(document.schemaVersion), at: 2, in: statement)
        try bind(Int64(document.geometrySemanticsVersion), at: 3, in: statement)
        try bind(String(checkpoint.checkpointVersion), at: 4, in: statement)
        try bind(checkpoint.sourceSceneId, at: 5, in: statement)
        try bind(checkpoint.sourceSceneId, at: 6, in: statement)
        try bind(String(checkpoint.sourceRevision), at: 7, in: statement)
        try bind(String(checkpoint.sourceIntentEpoch), at: 8, in: statement)
        try bind(json, at: 9, in: statement)
        try bind(checkpoint.savedAt.timeIntervalSince1970, at: 10, in: statement)
        try stepDone(statement)
    }

    func documentRow(documentId: String) throws -> StoredDocumentRow? {
        let statement = try prepare(
            """
            SELECT schema_version, geometry_semantics_version, checkpoint_version,
                   source_scene_id, source_revision, source_intent_epoch, saved_at, scene_json
            FROM documents WHERE document_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(documentId, at: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            try throwLastError()
        }
        return StoredDocumentRow(
            json: try blob(at: 7, in: statement),
            checkpoint: try checkpoint(documentId: documentId, from: statement, offset: 2),
            schemaVersion: Int(sqlite3_column_int(statement, 0)),
            geometrySemanticsVersion: Int(sqlite3_column_int(statement, 1))
        )
    }

    func documentMetadata(documentId: String) throws -> StoredDocumentMetadata? {
        let statement = try prepare(
            """
            SELECT checkpoint_version, source_scene_id, source_revision, source_intent_epoch, saved_at, active_scene_id
            FROM documents WHERE document_id = ?
            """
        )
        defer { sqlite3_finalize(statement) }
        try bind(documentId, at: 1, in: statement)
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW else {
            if result == SQLITE_DONE { return nil }
            try throwLastError()
        }
        return StoredDocumentMetadata(
            checkpoint: try checkpoint(documentId: documentId, from: statement),
            activeSceneId: try text(at: 5, in: statement)
        )
    }

    func admit(sceneId: String, for documentId: String) throws {
        let statement = try prepare("UPDATE documents SET active_scene_id = ? WHERE document_id = ?")
        defer { sqlite3_finalize(statement) }
        try bind(sceneId, at: 1, in: statement)
        try bind(documentId, at: 2, in: statement)
        try stepDone(statement)
        guard sqlite3_changes(checkedHandle) == 1 else {
            throw SceneDocumentStoreError.missingDocument(documentId)
        }
    }

    func allMetadata() throws -> [SavedCheckpoint] {
        let statement = try prepare(
            """
            SELECT document_id, checkpoint_version, source_scene_id, source_revision, source_intent_epoch, saved_at
            FROM documents ORDER BY saved_at DESC, document_id ASC
            """
        )
        defer { sqlite3_finalize(statement) }

        var checkpoints: [SavedCheckpoint] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return checkpoints }
            guard result == SQLITE_ROW else { try throwLastError() }
            checkpoints.append(try checkpoint(documentId: try text(at: 0, in: statement), from: statement, offset: 1))
        }
    }

    private var checkedHandle: OpaquePointer {
        guard let handle else { fatalError("SQLite database was closed") }
        return handle
    }

    private func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        let result = sqlite3_exec(checkedHandle, sql, nil, nil, &errorMessage)
        defer { sqlite3_free(errorMessage) }
        guard result == SQLITE_OK else {
            throw SceneDocumentStoreError.sqlite(
                code: result,
                message: errorMessage.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(checkedHandle))
            )
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        var statement: OpaquePointer?
        let result = sqlite3_prepare_v2(checkedHandle, sql, -1, &statement, nil)
        guard result == SQLITE_OK, let statement else { try throwLastError() }
        return statement
    }

    private func bind(_ value: String, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        guard result == SQLITE_OK else { try throwLastError() }
    }

    private func bind(_ value: Int64, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_int64(statement, index, value)
        guard result == SQLITE_OK else { try throwLastError() }
    }

    private func bind(_ value: Double, at index: Int32, in statement: OpaquePointer) throws {
        let result = sqlite3_bind_double(statement, index, value)
        guard result == SQLITE_OK else { try throwLastError() }
    }

    private func bind(_ value: Data, at index: Int32, in statement: OpaquePointer) throws {
        let result = value.withUnsafeBytes { bytes in
            sqlite3_bind_blob(statement, index, bytes.baseAddress, Int32(value.count), sqliteTransient)
        }
        guard result == SQLITE_OK else { try throwLastError() }
    }

    private func stepDone(_ statement: OpaquePointer) throws {
        let result = sqlite3_step(statement)
        guard result == SQLITE_DONE else { try throwLastError() }
    }

    private func checkpoint(documentId: String, from statement: OpaquePointer, offset: Int32 = 0) throws -> SavedCheckpoint {
        let version = try unsignedInteger(at: offset, in: statement, columnName: "checkpoint_version")
        let sourceSceneId = try text(at: offset + 1, in: statement)
        let revision = try unsignedInteger(at: offset + 2, in: statement, columnName: "source_revision")
        let epoch = try unsignedInteger(at: offset + 3, in: statement, columnName: "source_intent_epoch")
        let savedAt = Date(timeIntervalSince1970: sqlite3_column_double(statement, offset + 4))
        return SavedCheckpoint(
            documentId: documentId,
            checkpointVersion: version,
            sourceSceneId: sourceSceneId,
            sourceRevision: revision,
            sourceIntentEpoch: epoch,
            savedAt: savedAt
        )
    }

    private func text(at column: Int32, in statement: OpaquePointer) throws -> String {
        guard let string = sqlite3_column_text(statement, column) else {
            throw SceneDocumentStoreError.malformedCheckpoint("required metadata is NULL")
        }
        return String(cString: string)
    }

    private func unsignedInteger(at column: Int32, in statement: OpaquePointer, columnName: String) throws -> UInt64 {
        guard let value = UInt64(try text(at: column, in: statement)) else {
            throw SceneDocumentStoreError.malformedCheckpoint("\(columnName) is not an unsigned integer")
        }
        return value
    }

    private func blob(at column: Int32, in statement: OpaquePointer) throws -> Data {
        let length = sqlite3_column_bytes(statement, column)
        guard length >= 0, let bytes = sqlite3_column_blob(statement, column) else {
            throw SceneDocumentStoreError.malformedCheckpoint("scene JSON is NULL")
        }
        return Data(bytes: bytes, count: Int(length))
    }

    private func throwLastError() throws -> Never {
        throw SceneDocumentStoreError.sqlite(
            code: sqlite3_errcode(checkedHandle),
            message: String(cString: sqlite3_errmsg(checkedHandle))
        )
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
