import Foundation
import SQLite3
import SpatialApple
import SpatialCore
import XCTest

final class SceneDocumentStoreTests: XCTestCase {
    func testRoundTripsCompleteDocumentAndMintsNewRuntimeIdentity() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-rack")
        let store = SceneDocumentStore(directoryURL: directory)
        let saved = try await store.save(
            document: document,
            sceneId: "live-scene-before-save",
            revision: 12,
            intentEpoch: 7
        )

        let loaded = try await store.load(documentId: document.documentId)

        XCTAssertEqual(loaded.document, document)
        XCTAssertNotEqual(loaded.sceneId, saved.sourceSceneId)
        XCTAssertEqual(loaded.revision, 0)
        XCTAssertEqual(loaded.intentEpoch, 0)
        XCTAssertEqual(loaded.checkpoint, saved)
        XCTAssertEqual(saved.checkpointVersion, 1)
        XCTAssertEqual(saved.sourceRevision, 12)
        XCTAssertEqual(saved.sourceIntentEpoch, 7)
    }

    func testRejectsOlderCheckpointFromTheActiveScene() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-ordering")
        let store = SceneDocumentStore(directoryURL: directory)
        _ = try await store.save(document: document, sceneId: "live-scene", revision: 9, intentEpoch: 2)

        do {
            try await store.save(document: document, sceneId: "live-scene", revision: 8, intentEpoch: 2)
            XCTFail("An older snapshot must not overwrite the saved checkpoint")
        } catch let error as SceneDocumentStoreError {
            XCTAssertEqual(error, .staleSave(documentId: document.documentId, sourceSceneId: "live-scene"))
        }
    }

    func testRejectsOldLiveSceneAfterReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-reopen-ordering")
        let store = SceneDocumentStore(directoryURL: directory)
        _ = try await store.save(document: document, sceneId: "old-live-scene", revision: 3, intentEpoch: 1)
        let reopened = try await store.load(documentId: document.documentId)

        do {
            _ = try await store.save(document: document, sceneId: "old-live-scene", revision: 4, intentEpoch: 1)
            XCTFail("A pending save from the old live scene must not overwrite a reopened document")
        } catch let error as SceneDocumentStoreError {
            XCTAssertEqual(error, .unknownLiveScene(documentId: document.documentId, sourceSceneId: "old-live-scene"))
        }

        let current = try await store.load(documentId: document.documentId)
        XCTAssertEqual(current.document, document)
        XCTAssertNotEqual(reopened.sceneId, current.sceneId)
    }

    func testRejectsObsoleteSaveFromAnotherStoreActorAfterReopen() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-cross-store")
        let originalStore = SceneDocumentStore(directoryURL: directory)
        _ = try await originalStore.save(document: document, sceneId: "old-process-scene", revision: 2, intentEpoch: 1)

        let reopenedStore = SceneDocumentStore(directoryURL: directory)
        let reopened = try await reopenedStore.load(documentId: document.documentId)
        _ = try await reopenedStore.save(document: document, sceneId: reopened.sceneId, revision: 0, intentEpoch: 0)

        do {
            _ = try await originalStore.save(document: document, sceneId: "old-process-scene", revision: 3, intentEpoch: 1)
            XCTFail("A separately retained store actor must not revive an obsolete live scene")
        } catch let error as SceneDocumentStoreError {
            XCTAssertEqual(error, .unknownLiveScene(documentId: document.documentId, sourceSceneId: "old-process-scene"))
        }

        let checkpoints = try await reopenedStore.list()
        XCTAssertEqual(checkpoints.single?.sourceSceneId, reopened.sceneId)
        XCTAssertEqual(checkpoints.single?.sourceRevision, 0)
    }

    func testReportsRequiredMetadataInList() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-metadata")
        let store = SceneDocumentStore(directoryURL: directory)
        let saved = try await store.save(document: document, sceneId: "source-9", revision: 42, intentEpoch: 11)

        let checkpoints = try await store.list()
        XCTAssertEqual(checkpoints, [saved])
    }

    func testRejectsMalformedStoredJSONInsteadOfInventingAScene() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let document = try makeDocument(documentId: "document-corrupt")
        let store = SceneDocumentStore(directoryURL: directory)
        _ = try await store.save(document: document, sceneId: "source-1", revision: 1, intentEpoch: 1)
        try overwriteCheckpointJSON(at: directory.appending(path: "scenes.sqlite"), documentId: document.documentId)

        do {
            try await store.load(documentId: document.documentId)
            XCTFail("Corrupt JSON must never produce a usable scene")
        } catch let error as SceneDocumentStoreError {
            guard case .malformedCheckpoint = error else {
                return XCTFail("Expected malformed checkpoint, got \(error)")
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "SpatialKitStorageTests")
            .appending(path: UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func makeDocument(documentId: String) throws -> SceneDocument {
        let recipe = GeometryRecipe.box(size: Vec3(0.44, 0.09, 0.71))
        return SceneDocument(
            documentId: documentId,
            geometryDefinitions: [
                GeometryDefinition(
                    geometryId: "geometry-chassis",
                    contentHash: try canonicalContentHash(for: recipe),
                    recipe: recipe
                )
            ],
            materials: [
                Material(materialId: "material-metal", baseColorLinear: [0.2, 0.22, 0.25, 1], metallic: 0.8, roughness: 0.35)
            ],
            nodes: [
                SceneNode(
                    nodeId: "rack-chassis",
                    geometryId: "geometry-chassis",
                    materialId: "material-metal",
                    semantic: NodeSemantic(name: "Rack chassis", role: "chassis"),
                    provenance: Provenance(origin: .authored, factualSupport: .illustrative)
                )
            ],
            relationships: []
        )
    }

    private func overwriteCheckpointJSON(at databaseURL: URL, documentId: String) throws {
        var database: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &database, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK, let database else {
            throw TestFailure.couldNotOpenDatabase
        }
        defer { sqlite3_close(database) }

        let sql = "UPDATE documents SET scene_json = X'7B6E6F742D6A736F6E' WHERE document_id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw TestFailure.couldNotPrepareStatement
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_bind_text(statement, 1, documentId, -1, sqliteTransient) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_DONE else {
            throw TestFailure.couldNotWriteCorruption
        }
    }
}

private enum TestFailure: Error {
    case couldNotOpenDatabase
    case couldNotPrepareStatement
    case couldNotWriteCorruption
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private extension Collection {
    var single: Element? { count == 1 ? first : nil }
}
