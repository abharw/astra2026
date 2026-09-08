# Storage and recovery

2026-09-08 · Architecture proposal. None of the storage, checkpoint, cache, or recovery behavior below is implemented or benchmarked.

The device owns the accepted scene. Saving preserves its editable source; the database does not generate assets. Astra produces a program or description, the generation pipeline normalizes it into a bounded intermediate representation (IR), and Swift constructs native geometry from that IR. Reopening a saved scene must not require executing the original program or calling a model again.

## 1. Source, artifacts, and runtime state

| Representation | Contents | Lifetime and location |
| --- | --- | --- |
| Scene document | Nodes, geometry definitions, materials, relationships, provenance, final/rest transforms | Complete JSON checkpoint in local SQLite |
| Original binaries | Imported USDZ, textures, externally generated meshes | Bundle or durable application files |
| Generation programs | Original source and generation metadata | Provenance files; retained as text, never executed on reopen |
| Compiled mesh data | Vertices, indices, bounds | Memory initially; optional discardable cache later |
| RealityKit objects | Entities, mesh resources, materials, collision/selection state | Process memory and GPU resources |
| Physical placement | Root placement and optional world-map association | Separate optional saved metadata |

The semantic document contains `schemaVersion: 1` and `geometrySemanticsVersion: 1`. Its geometry definitions are immutable and have a `geometryId` plus a SHA-256 content hash. Scene nodes have separate stable IDs and reference those definitions. Replacing geometry creates or reuses another definition; changing a node transform does not rewrite its geometry.

The saved normalized IR is the reconstruction source. The original program explains how it was produced. An externally generated binary that cannot be reproduced from IR is itself a source artifact and must be retained.

## 2. Milestones and ownership

The first live spike keeps its accepted scene in memory. Local Save/Open is the next storage milestone, followed by coalesced autosave. Disk mesh caching follows only if measured reconstruction cost justifies it. Cloud storage is a later feature.

Introduce a stable `documentId` when saving begins. A `sceneId` identifies one live session. Reopening a document creates a new scene ID and initializes its scene revision and intent epoch; old requests, receipts, and pending jobs cannot mutate that session. The checkpoint retains its source scene ID and revision for provenance.

SQLite stores the last saved checkpoint. The current in-memory scene can be newer. The backend keeps an acknowledged mirror for model context; it does not independently accept scene edits. RealityKit is the presentation of accepted semantic state.

SQLite fits local application documents with modest writer concurrency and avoids requiring a network connection to save. This is consistent with its documented application-file and device-storage uses. [SQLite appropriate uses](https://www.sqlite.org/whentouse.html).

## 3. Proposed disk layout and schema

Resolve directories through Foundation; do not persist absolute iOS sandbox paths.

```text
Application Support/SpatialKit/
  scenes.sqlite
  artifacts/sha256/<digest>         # Immutable original assets/program text
  world-maps/<map-id>.archive       # Optional; separate from semantic source
Caches/SpatialKit/
  meshes/<cache-key>                # Reconstructible compiled data
  thumbnails/<cache-key>
tmp/SpatialKit/
  imports/<temporary-id>
```

Application Support holds required source and saved documents. Caches contains only replaceable data; Apple does not back up the caches directory. Bundled seed assets remain in the bundle and are referenced by pack identity, version, and hash. [Apple file-system guidance](https://developer.apple.com/documentation/foundation/using-the-file-system-effectively).

Proposed starting schema:

```sql
PRAGMA foreign_keys = ON;
PRAGMA journal_mode = WAL;
PRAGMA synchronous = FULL;

CREATE TABLE documents (
  document_id TEXT PRIMARY KEY,
  title TEXT NOT NULL,
  schema_version INTEGER NOT NULL,
  checkpoint_version INTEGER NOT NULL,
  source_scene_id TEXT NOT NULL,
  source_revision INTEGER NOT NULL,
  scene_json BLOB NOT NULL,
  saved_at TEXT NOT NULL
);

CREATE TABLE changes (
  document_id TEXT NOT NULL REFERENCES documents(document_id),
  source_scene_id TEXT NOT NULL,
  request_id TEXT NOT NULL,
  base_revision INTEGER NOT NULL,
  result_revision INTEGER NOT NULL,
  payload_hash TEXT NOT NULL,
  patch_json BLOB NOT NULL,
  affected_before_json BLOB,
  model_response_id TEXT,
  installed_at TEXT NOT NULL,
  PRIMARY KEY (source_scene_id, request_id)
);

CREATE TABLE artifacts (
  content_hash TEXT PRIMARY KEY,
  media_type TEXT NOT NULL,
  byte_length INTEGER NOT NULL,
  location_kind TEXT NOT NULL,
  location_reference TEXT NOT NULL,
  provenance_json BLOB NOT NULL
);
```

JSON blobs contain canonical UTF-8 document data, not database-specific serialized Swift objects. The application validates the complete document and every referenced artifact before saving or opening it. SQL constraints alone cannot validate references embedded in JSON.

`changes` holds bounded inspection and undo evidence, not a replay log required to reconstruct the document. Its `base_revision` records the actual immediately preceding committed revision, including for a generation batch whose wire precondition uses scope/sequence. Start with whole snapshots instead of normalizing every node into SQL rows. Add finer storage only when measured scene sizes or query needs justify it. Keep SQL in a concrete device storage component; `SpatialCore` owns document values and migrations without importing SQLite.

## 4. Installation and checkpoint ordering

An `installed` receipt means the accepted semantic scene and native entities were updated. It does not mean saved, animation-complete, or physically displayed.

1. Validate the proposal and prepare immutable resources; defer references to earlier queued batches until those dependencies commit.
2. Recheck scene ID and intent epoch, plus strict base revision for ordinary edits or active generation scope, ownership and expected sequence for generation batches.
3. Apply operations to the current accepted scene and install prepared resources in the existing bounded, serialized native commit. Do not replace current state with an old snapshot captured during preparation.
4. Emit `installed` and enqueue an immutable semantic snapshot with its associated history.
5. A storage worker validates references and writes the checkpoint, metadata, and retained history in one SQLite transaction.
6. After commit, emit `checkpoint_saved` with document ID, checkpoint version, source scene ID, and source revision.

The main actor never waits for SQLite, filesystem synchronization, or cloud upload to install a live change. Coalesce pending autosaves to the newest snapshot. Retain the history required by the selected bounded-history policy even when intermediate snapshots are skipped. Assign a document-local monotonically increasing save sequence, persisted as `checkpoint_version`; live scene revisions reset on reopen and cannot order document saves across sessions. Serialize writes, reject obsolete checkpoint work, and never let an older snapshot overwrite a newer checkpoint.

A manual Save captures a specific revision, pins its snapshot against coalescing, and completes when that checkpoint commits. Process it in save-sequence order before later snapshots. An autosave failure leaves the scene interactive and records an unsaved state. Do not persist camera poses or animation frames. Persist desired/rest poses and any required declarative animation intent.

Undo changes the current scene through a new validated transaction and produces another revision. Saved preimages are inspection evidence; v0 does not promise that live undo survives closing and reopening a document.

## 5. Files and crash windows

SQLite transactions do not atomically include external asset files, RealityKit entities, GPU frames, and network receipts. Avoid claiming a universal commit across them. [SQLite atomic commit](https://www.sqlite.org/atomiccommit.html).

For a new binary or provenance file, write to a temporary location, validate it, calculate its hash, and move it to its immutable destination before publishing a document reference. Add metadata only after the file is ready. A crash between file installation and database commit can leave an orphan; later garbage collection can remove unreferenced files. Atomic file replacement does not make a database update part of that operation. Power-loss durability of required external assets needs an explicit tested file/directory flush policy; SQLite `FULL` alone does not establish that guarantee. [Apple writing options](https://developer.apple.com/documentation/foundation/nsdata/writingoptions).

| Failure | Defined behavior |
| --- | --- |
| Geometry preparation fails | Retain the previous live scene |
| Installed, then terminated before save | Reopen the previous checkpoint; latest unsaved edits may be lost |
| Interrupted SQLite transaction | Recover the preceding or completed checkpoint, never partial document JSON |
| Saved, but notification lost | Read committed checkpoint metadata |
| Referenced file missing or corrupt | Preserve document source; report an unavailable asset and reacquire when possible |
| Native reconstruction fails | Preserve source and expose the loading failure |
| Backend restarts | Rebuild context from a fresh device snapshot |

Referenced source files must be protected from cache eviction and garbage collection while needed by a retained checkpoint, current live scene, pending checkpoint, or in-flight import. Release those holds deliberately; checking saved database references alone can delete an asset that is installed but not yet saved. Storage errors must never be silently reported as successful saves.

## 6. Hashes, versions, and caching

Hash schema-normalized, canonically encoded UTF-8 geometry bytes. The format specification must define defaults, numeric normalization, coordinates, and encoding; shared Swift/TypeScript fixtures must produce identical hashes. Include the geometry semantics version in hashed source. Exclude node IDs, labels, placement transforms, and material bindings from geometry content hashes.

```text
meshCacheKey = SHA256(
  canonicalUTF8({
    geometryContentHash,
    geometryCompilerVersion,
    tessellationProfile,
    compiledFormatVersion
  })
)
```

Materials have separate description hashes and resource caches. Include the material adapter/render-profile version in their cache keys. A material edit should not rebuild vertices. Add platform compatibility to a mesh key when its binary representation actually depends on that platform.

Compiler upgrades invalidate affected caches, not documents. Schema migrations preserve the original source until the replacement checkpoint saves successfully. Content hashes identify bytes, not factual accuracy. Cross-platform semantic compatibility does not imply bit-identical floating-point meshes without verification.

## 7. Persistence performance and AR restoration

Encode snapshots and perform database work away from the main actor. Bound snapshot sizes and queued work. Start with WAL and `synchronous=FULL` because saves are coalesced and outside the interactive installation path. Profile encoding, write frequency, and storage latency before changing durability settings. WAL `NORMAL` can lose recent commits after power loss or hard reset; application-crash recovery is a different guarantee. [SQLite WAL](https://www.sqlite.org/wal.html), [synchronous settings](https://www.sqlite.org/pragma.html#pragma_synchronous).

A saved semantic scene is independent of successful physical relocalization. V0 restores content and lets the user place it again. Later, an optional `ARWorldMap` can help recover a prior physical anchor, but ARKit must still relocalize against the environment. Show tracking status and retain a re-placement fallback. [Apple world-data restoration](https://developer.apple.com/documentation/ARKit/saving-and-loading-world-data).

## 8. Backend evidence and future cloud storage

The initial backend needs an acknowledged scene mirror, pending model/job state, and bounded JSONL evidence. Evidence records correlate model responses, proposed IR, validation, receipts, and timings; they never override device acceptance. A complete public judging run is exported and checked explicitly, rather than assumed from best-effort logging.

No Postgres or object store is required for this version. If cloud document libraries become necessary, object storage can hold immutable binaries and scene packages while Postgres tracks ownership and checkpoint pointers. Upload referenced blobs before publishing their manifest. An uploaded checkpoint is not a device installation receipt.

Use a single active editor or deliberate document forks before introducing concurrent scene merges. Keep cloud backup outside the live generation path. For portable inspection, export semantic JSON plus referenced assets and provenance. If exporting the SQLite database itself, use its backup API rather than copying only a live database file with outstanding WAL state. [SQLite backup API](https://www.sqlite.org/backup.html).
