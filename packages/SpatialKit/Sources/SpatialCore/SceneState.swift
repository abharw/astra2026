import Foundation

public struct SceneState: Sendable, Equatable {
  public static let maximumWireInteger: UInt64 = 9_007_199_254_740_991

  public private(set) var sceneId: String
  public private(set) var revision: UInt64
  public private(set) var intentEpoch: UInt64
  public private(set) var document: SceneDocument

  private var activeGeneration: GenerationScope?
  private var requestRecords: [String: RequestRecord] = [:]
  private var undoStack: [SceneDocument] = []
  private let validator: SceneValidator

  public static func == (lhs: SceneState, rhs: SceneState) -> Bool {
    lhs.sceneId == rhs.sceneId
      && lhs.revision == rhs.revision
      && lhs.intentEpoch == rhs.intentEpoch
      && lhs.document == rhs.document
  }

  public init(
    document: SceneDocument, sceneId: String, revision: UInt64 = 0, intentEpoch: UInt64 = 0,
    budgets: SceneBudgets = .default
  ) throws {
    guard !sceneId.isEmpty, sceneId.utf8.count <= 128 else {
      throw SceneValidationError.invalidIdentifier("sceneId")
    }
    guard revision <= Self.maximumWireInteger, intentEpoch <= Self.maximumWireInteger else {
      throw SceneValidationError.invalidNumber("revision or intentEpoch")
    }
    let validator = SceneValidator(budgets: budgets)
    try validator.validate(document)
    self.sceneId = sceneId
    self.revision = revision
    self.intentEpoch = intentEpoch
    self.document = document
    self.validator = validator
  }

  public mutating func apply(_ message: ClientMessage) -> ApplyReceipt {
    switch message {
    case .hello:
      return .generation(
        GenerationReceipt(
          sceneId: sceneId, generationId: "", requestId: "", status: .rejected, revision: revision,
          committedSequence: 0,
          rejection: Rejection(
            code: "invalid_message",
            message: "hello is negotiated by transport, not applied to scene state")))
    case .generationBegin(let value): return apply(value, original: message)
    case .generationBatch(let value): return apply(value, original: message)
    case .generationFinish(let value): return apply(value, original: message)
    case .scenePatch(let value): return apply(value, original: message)
    }
  }

  @discardableResult
  public mutating func advanceIntentEpoch() -> UInt64 {
    precondition(intentEpoch < Self.maximumWireInteger, "intentEpoch exhausted its wire range")
    intentEpoch += 1
    activeGeneration = nil
    return intentEpoch
  }

  public mutating func undo(requestId: String) -> SceneReceipt {
    if let existing = requestRecords[requestId] {
      if case .scene(let receipt) = existing.receipt, existing.message == nil { return receipt }
      return rejectedScene(
        requestId: requestId, code: "request_id_conflict", message: "requestId was already used")
    }
    guard let previous = undoStack.popLast() else {
      return rejectedScene(
        requestId: requestId, code: "nothing_to_undo",
        message: "No committed transaction is available to undo")
    }
    let affected = Set(document.nodes.map(\.nodeId)).union(previous.nodes.map(\.nodeId)).sorted()
    document = previous
    revision &+= 1
    activeGeneration = nil
    let receipt = SceneReceipt(
      sceneId: sceneId, requestId: requestId, status: .installed, revision: revision,
      affectedNodeIds: affected)
    requestRecords[requestId] = RequestRecord(message: nil, receipt: .scene(receipt))
    return receipt
  }

  private mutating func apply(_ begin: GenerationBegin, original: ClientMessage) -> ApplyReceipt {
    if let prior = replayOrConflict(requestId: begin.requestId, message: original) { return prior }
    guard begin.protocolVersion == 1 else {
      return recordGenerationRejection(
        begin, original, code: "unsupported_version", message: "protocolVersion must be 1")
    }
    guard begin.sceneId == sceneId else {
      return recordGenerationRejection(
        begin, original, code: "wrong_scene", message: "sceneId does not identify the active scene")
    }
    guard begin.intentEpoch == intentEpoch else {
      return recordGenerationRejection(
        begin, original, code: "stale_epoch", message: "intentEpoch is not current")
    }
    guard begin.initialBaseRevision == revision else {
      return recordGenerationRejection(
        begin, original, code: "revision_conflict", message: "initialBaseRevision is not current",
        expectedRevision: revision)
    }
    if let parent = begin.scopeParentNodeId,
      !document.nodes.contains(where: { $0.nodeId == parent })
    {
      return recordGenerationRejection(
        begin, original, code: "missing_reference", message: "scope parent does not exist")
    }
    activeGeneration = GenerationScope(
      generationId: begin.generationId, epoch: begin.intentEpoch,
      parentNodeId: begin.scopeParentNodeId)
    let receipt = GenerationReceipt(
      sceneId: sceneId, generationId: begin.generationId, requestId: begin.requestId,
      status: .accepted, revision: revision, committedSequence: 0)
    return record(begin.requestId, original, .generation(receipt))
  }

  private mutating func apply(_ batch: GenerationBatch, original: ClientMessage) -> ApplyReceipt {
    if let prior = replayOrConflict(requestId: batch.requestId, message: original) { return prior }
    guard batch.protocolVersion == 1 else {
      return recordSceneRejection(
        batch, original, code: "unsupported_version", message: "protocolVersion must be 1")
    }
    guard batch.sceneId == sceneId else {
      return recordSceneRejection(
        batch, original, code: "wrong_scene", message: "sceneId does not identify the active scene")
    }
    guard batch.intentEpoch == intentEpoch else {
      return recordSceneRejection(
        batch, original, code: "stale_epoch", message: "intentEpoch is not current")
    }
    guard let scope = activeGeneration, scope.generationId == batch.generationId,
      scope.epoch == batch.intentEpoch
    else {
      return recordSceneRejection(
        batch, original, code: "inactive_generation", message: "generation scope is not active")
    }
    guard batch.sequence == scope.committedSequence + 1 else {
      return recordSceneRejection(
        batch, original, code: "sequence_gap", message: "batch is not the next sequence",
        expectedSequence: scope.committedSequence + 1)
    }
    do {
      guard try canonicalPayloadHash(for: batch) == batch.payloadHash else {
        return recordSceneRejection(
          batch, original, code: "hash_mismatch", message: "payloadHash does not bind this request")
      }
      try validator.validate(operations: batch.operations)
      var candidate = document
      var nextScope = scope
      let affected = try apply(batch.operations, to: &candidate, generation: &nextScope)
      try validator.validate(candidate)
      undoStack.append(document)
      document = candidate
      revision &+= 1
      nextScope.committedSequence = batch.sequence
      activeGeneration = nextScope
      let receipt = SceneReceipt(
        sceneId: sceneId, generationId: batch.generationId, requestId: batch.requestId,
        sequence: batch.sequence, status: .installed, revision: revision,
        affectedNodeIds: affected.sorted())
      return record(batch.requestId, original, .scene(receipt))
    } catch {
      return recordSceneRejection(
        batch, original, code: "validation_failed", message: String(describing: error))
    }
  }

  private mutating func apply(_ finish: GenerationFinish, original: ClientMessage) -> ApplyReceipt {
    if let prior = replayOrConflict(requestId: finish.requestId, message: original) { return prior }
    guard finish.sceneId == sceneId, finish.intentEpoch == intentEpoch,
      let scope = activeGeneration, scope.generationId == finish.generationId,
      scope.epoch == finish.intentEpoch
    else {
      return recordGenerationRejection(
        finish, original, code: "inactive_generation", message: "generation scope is not active")
    }
    guard finish.lastSequence == scope.committedSequence else {
      return recordGenerationRejection(
        finish, original, code: "sequence_incomplete",
        message: "finish does not match the committed sequence",
        expectedSequence: scope.committedSequence)
    }
    activeGeneration = nil
    let receipt = GenerationReceipt(
      sceneId: sceneId, generationId: finish.generationId, requestId: finish.requestId,
      status: .completed, revision: revision, committedSequence: scope.committedSequence)
    return record(finish.requestId, original, .generation(receipt))
  }

  private mutating func apply(_ patch: ScenePatch, original: ClientMessage) -> ApplyReceipt {
    if let prior = replayOrConflict(requestId: patch.requestId, message: original) { return prior }
    guard patch.protocolVersion == 1 else {
      return recordPatchRejection(
        patch, original, code: "unsupported_version", message: "protocolVersion must be 1")
    }
    guard patch.sceneId == sceneId else {
      return recordPatchRejection(
        patch, original, code: "wrong_scene", message: "sceneId does not identify the active scene")
    }
    guard patch.intentEpoch == intentEpoch else {
      return recordPatchRejection(
        patch, original, code: "stale_epoch", message: "intentEpoch is not current")
    }
    guard patch.baseRevision == revision else {
      return recordPatchRejection(
        patch, original, code: "revision_conflict", message: "baseRevision is not current",
        expectedRevision: revision)
    }
    do {
      guard try canonicalPayloadHash(for: patch) == patch.payloadHash else {
        return recordPatchRejection(
          patch, original, code: "hash_mismatch", message: "payloadHash does not bind this request")
      }
      try validator.validate(operations: patch.operations)
      var candidate = document
      let affected = try apply(patch.operations, to: &candidate)
      try validator.validate(candidate)
      undoStack.append(document)
      document = candidate
      revision &+= 1
      activeGeneration = nil
      let receipt = SceneReceipt(
        sceneId: sceneId, requestId: patch.requestId, status: .installed, revision: revision,
        affectedNodeIds: affected.sorted())
      return record(patch.requestId, original, .scene(receipt))
    } catch {
      return recordPatchRejection(
        patch, original, code: "validation_failed", message: String(describing: error))
    }
  }

  private func apply(_ operations: [SceneOperation], to document: inout SceneDocument) throws
    -> Set<String>
  {
    var affected = Set<String>()
    for operation in operations { try apply(operation, to: &document, affected: &affected) }
    return affected
  }

  private func apply(
    _ operations: [SceneOperation], to document: inout SceneDocument,
    generation scope: inout GenerationScope
  ) throws -> Set<String> {
    var affected = Set<String>()
    for operation in operations {
      switch operation {
      case .putGeometry(let value):
        guard !document.geometryDefinitions.contains(where: { $0.geometryId == value.geometryId })
        else { throw SceneValidationError.immutableDefinition(value.geometryId) }
        scope.geometryIds.insert(value.geometryId)
      case .putMaterial(let value):
        guard !document.materials.contains(where: { $0.materialId == value.materialId }) else {
          throw SceneValidationError.immutableDefinition(value.materialId)
        }
        scope.materialIds.insert(value.materialId)
      case .createNode(let node):
        let allowedParent =
          node.parentId == scope.parentNodeId || node.parentId.map(scope.nodeIds.contains) == true
          || (scope.parentNodeId == nil && node.parentId == nil)
        guard allowedParent else {
          throw SceneValidationError.invalidOperation("generation parent outside scope")
        }
        scope.nodeIds.insert(node.nodeId)
      case .putRelationship(let value):
        let allowed =
          scope.nodeIds.contains(value.sourceNodeId)
          && (scope.nodeIds.contains(value.targetNodeId)
            || value.targetNodeId == scope.parentNodeId)
          || scope.nodeIds.contains(value.targetNodeId) && value.sourceNodeId == scope.parentNodeId
        guard allowed else {
          throw SceneValidationError.invalidOperation("relationship outside generation scope")
        }
        scope.relationshipIds.insert(value.relationshipId)
      case .removeNode(let nodeId), .setTransform(let nodeId, _), .setGeometry(let nodeId, _),
        .setMaterial(let nodeId, _), .setVisibility(let nodeId, _):
        guard scope.nodeIds.contains(nodeId) else {
          throw SceneValidationError.invalidOperation(
            "generation cannot mutate pre-existing node \(nodeId)")
        }
      case .removeRelationship(let relationshipId):
        guard scope.relationshipIds.contains(relationshipId) else {
          throw SceneValidationError.invalidOperation(
            "generation cannot remove pre-existing relationship")
        }
      }
      try apply(operation, to: &document, affected: &affected)
    }
    return affected
  }

  private func apply(
    _ operation: SceneOperation, to document: inout SceneDocument, affected: inout Set<String>
  ) throws {
    switch operation {
    case .putGeometry(let value):
      if let existing = document.geometryDefinitions.first(where: {
        $0.geometryId == value.geometryId
      }) {
        guard existing == value else {
          throw SceneValidationError.immutableDefinition(value.geometryId)
        }
      } else {
        document.geometryDefinitions.append(value)
      }
    case .putMaterial(let value):
      if let existing = document.materials.first(where: { $0.materialId == value.materialId }) {
        guard existing == value else {
          throw SceneValidationError.immutableDefinition(value.materialId)
        }
      } else {
        document.materials.append(value)
      }
    case .createNode(let value):
      guard !document.nodes.contains(where: { $0.nodeId == value.nodeId }) else {
        throw SceneValidationError.duplicateIdentifier(value.nodeId)
      }
      document.nodes.append(value)
      affected.insert(value.nodeId)
    case .removeNode(let nodeId):
      guard let index = document.nodes.firstIndex(where: { $0.nodeId == nodeId }) else {
        throw SceneValidationError.missingReference(nodeId)
      }
      document.nodes.remove(at: index)
      affected.insert(nodeId)
    case .setTransform(let nodeId, let transform):
      try mutateNode(nodeId, in: &document) { $0.transform = transform }
      affected.insert(nodeId)
    case .setGeometry(let nodeId, let geometryId):
      try mutateNode(nodeId, in: &document) { $0.geometryId = geometryId }
      affected.insert(nodeId)
    case .setMaterial(let nodeId, let materialId):
      try mutateNode(nodeId, in: &document) { $0.materialId = materialId }
      affected.insert(nodeId)
    case .setVisibility(let nodeId, let isVisible):
      try mutateNode(nodeId, in: &document) { $0.isVisible = isVisible }
      affected.insert(nodeId)
    case .putRelationship(let value):
      guard !document.relationships.contains(where: { $0.relationshipId == value.relationshipId })
      else { throw SceneValidationError.duplicateIdentifier(value.relationshipId) }
      document.relationships.append(value)
      affected.insert(value.sourceNodeId)
      affected.insert(value.targetNodeId)
    case .removeRelationship(let relationshipId):
      guard
        let index = document.relationships.firstIndex(where: { $0.relationshipId == relationshipId }
        )
      else { throw SceneValidationError.missingReference(relationshipId) }
      let value = document.relationships.remove(at: index)
      affected.insert(value.sourceNodeId)
      affected.insert(value.targetNodeId)
    }
  }

  private func mutateNode(
    _ nodeId: String, in document: inout SceneDocument, mutation: (inout SceneNode) -> Void
  ) throws {
    guard let index = document.nodes.firstIndex(where: { $0.nodeId == nodeId }) else {
      throw SceneValidationError.missingReference(nodeId)
    }
    mutation(&document.nodes[index])
  }

  private mutating func replayOrConflict(requestId: String, message: ClientMessage) -> ApplyReceipt?
  {
    guard let existing = requestRecords[requestId] else { return nil }
    if existing.message == message { return existing.receipt }
    let rejection = Rejection(
      code: "request_id_conflict",
      message: "requestId was reused with different request content")
    switch message {
    case .generationBegin(let value):
      return .generation(
        GenerationReceipt(
          sceneId: sceneId, generationId: value.generationId, requestId: requestId,
          status: .rejected, revision: revision,
          committedSequence: activeGeneration?.committedSequence ?? 0, rejection: rejection))
    case .generationFinish(let value):
      return .generation(
        GenerationReceipt(
          sceneId: sceneId, generationId: value.generationId, requestId: requestId,
          status: .rejected, revision: revision,
          committedSequence: activeGeneration?.committedSequence ?? 0, rejection: rejection))
    case .generationBatch(let value):
      return .scene(
        SceneReceipt(
          sceneId: sceneId, generationId: value.generationId, requestId: requestId,
          sequence: value.sequence, status: .rejected, revision: revision,
          rejection: rejection))
    case .scenePatch:
      return .scene(
        rejectedScene(
          requestId: requestId, code: rejection.code, message: rejection.message))
    case .hello:
      return nil
    }
  }

  private mutating func record(
    _ requestId: String, _ message: ClientMessage, _ receipt: ApplyReceipt
  ) -> ApplyReceipt {
    requestRecords[requestId] = RequestRecord(message: message, receipt: receipt)
    return receipt
  }

  private func rejectedScene(
    requestId: String, generationId: String? = nil, sequence: UInt64? = nil, code: String,
    message: String, expectedRevision: UInt64? = nil, expectedSequence: UInt64? = nil
  ) -> SceneReceipt {
    SceneReceipt(
      sceneId: sceneId, generationId: generationId, requestId: requestId, sequence: sequence,
      status: .rejected, revision: revision,
      rejection: Rejection(
        code: code, message: message, expectedRevision: expectedRevision,
        expectedSequence: expectedSequence))
  }

  private mutating func recordSceneRejection(
    _ batch: GenerationBatch, _ original: ClientMessage, code: String, message: String,
    expectedSequence: UInt64? = nil
  ) -> ApplyReceipt {
    record(
      batch.requestId, original,
      .scene(
        rejectedScene(
          requestId: batch.requestId, generationId: batch.generationId, sequence: batch.sequence,
          code: code, message: message, expectedSequence: expectedSequence)))
  }
  private mutating func recordPatchRejection(
    _ patch: ScenePatch, _ original: ClientMessage, code: String, message: String,
    expectedRevision: UInt64? = nil
  ) -> ApplyReceipt {
    record(
      patch.requestId, original,
      .scene(
        rejectedScene(
          requestId: patch.requestId, code: code, message: message,
          expectedRevision: expectedRevision)))
  }
  private mutating func recordGenerationRejection(
    _ begin: GenerationBegin, _ original: ClientMessage, code: String, message: String,
    expectedRevision: UInt64? = nil
  ) -> ApplyReceipt {
    let value = GenerationReceipt(
      sceneId: sceneId, generationId: begin.generationId, requestId: begin.requestId,
      status: .rejected, revision: revision, committedSequence: 0,
      rejection: Rejection(code: code, message: message, expectedRevision: expectedRevision))
    return record(begin.requestId, original, .generation(value))
  }
  private mutating func recordGenerationRejection(
    _ finish: GenerationFinish, _ original: ClientMessage, code: String, message: String,
    expectedSequence: UInt64? = nil
  ) -> ApplyReceipt {
    let value = GenerationReceipt(
      sceneId: sceneId, generationId: finish.generationId, requestId: finish.requestId,
      status: .rejected, revision: revision,
      committedSequence: activeGeneration?.committedSequence ?? 0,
      rejection: Rejection(code: code, message: message, expectedSequence: expectedSequence))
    return record(finish.requestId, original, .generation(value))
  }
}

private struct RequestRecord: Sendable, Equatable {
  var message: ClientMessage?
  var receipt: ApplyReceipt
}
private struct GenerationScope: Sendable, Equatable {
  var generationId: String
  var epoch: UInt64
  var parentNodeId: String?
  var committedSequence: UInt64 = 0
  var nodeIds: Set<String> = []
  var geometryIds: Set<String> = []
  var materialIds: Set<String> = []
  var relationshipIds: Set<String> = []
}
