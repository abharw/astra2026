import { createHash } from "node:crypto";
import { JsonObject, ProtocolError, isObject } from "./json.js";
import { ModelEvent, ModelTransport } from "./astra/client.js";
import { NormalizedProposal, normalizeProposal, parseAuthoringProposal, payloadHash } from "./normalizer.js";
import { GenerationReceipt, PhoneSnapshot, PROTOCOL_VERSION, SceneReceipt, SessionHello, UserRequest } from "./protocol.js";

export interface SessionSink { send(message: JsonObject): void }

interface Snapshot {
  sceneId: string;
  revision: number;
  intentEpoch: number;
  document: JsonObject;
}

interface PendingProposal {
  requestId: string;
  intentEpoch: number;
  explanation: string;
  proposalRequestIds: string[];
}

interface ActiveRun { controller: AbortController; requestId: string; admission: Snapshot }

export class AstraSession {
  private hello?: SessionHello;
  private snapshot?: Snapshot;
  private readonly active = new Map<string, ActiveRun>();
  private readonly pending = new Map<string, PendingProposal>();
  private readonly completed = new Set<string>();

  constructor(private readonly model: ModelTransport, private sink: SessionSink) {}

  attachSink(sink: SessionSink): void { this.sink = sink; }

  acceptHello(hello: SessionHello): void {
    if (hello.protocolVersion !== PROTOCOL_VERSION || !hello.sceneSchemaVersions.includes(1) || !hello.geometrySemanticsVersions.includes(1)) {
      throw new ProtocolError("no compatible protocol/schema/geometry version", "unsupported_version");
    }
    if (this.hello && this.hello.sessionId !== hello.sessionId) throw new ProtocolError("connection cannot change sessionId", "session_mismatch");
    this.hello = hello;
    this.snapshot = undefined;
    this.send({ type: "session.accepted", protocolVersion: PROTOCOL_VERSION, sessionId: hello.sessionId, sceneSchemaVersion: 1, geometrySemanticsVersion: 1 });
  }

  updateSnapshot(message: PhoneSnapshot): void {
    this.ensureHello();
    if (message.sceneId !== this.hello!.sceneId) throw new ProtocolError("snapshot sceneId differs from hello", "scene_mismatch");
    const previous = this.snapshot;
    if (previous && (message.intentEpoch < previous.intentEpoch || (message.intentEpoch === previous.intentEpoch && message.revision < previous.revision))) {
      throw new ProtocolError("snapshot cannot move epoch or revision backwards", "stale_snapshot");
    }
    this.snapshot = { sceneId: message.sceneId, revision: message.revision, intentEpoch: message.intentEpoch, document: message.document };
  }

  async request(message: UserRequest): Promise<void> {
    this.ensureHello();
    const admission = this.requireSnapshot();
    if (this.completed.has(message.requestId) || this.active.has(message.requestId)) return;
    const controller = new AbortController();
    this.active.set(message.requestId, { controller, requestId: message.requestId, admission });
    this.send({ type: "session.progress", requestId: message.requestId, status: "thinking", intentEpoch: admission.intentEpoch });
    try {
      let functionCall = await this.collectFunctionCall(message, admission, controller.signal, message.text);
      if (controller.signal.aborted) return;
      this.assertAdmissionCurrent(admission);
      let normalized: NormalizedProposal;
      try {
        normalized = normalizeProposal(message.requestId, parseAuthoringProposal(JSON.parse(functionCall) as unknown), observedNodeIds(admission.document));
      } catch (error) {
        if (!(error instanceof ProtocolError) || error.code !== "proposal_rejected") throw error;
        recordDiscardedProposal(message.requestId, error.message, functionCall);
        this.send({ type: "session.progress", requestId: message.requestId, status: "repairing_proposal", intentEpoch: admission.intentEpoch });
        functionCall = await this.collectFunctionCall(message, admission, controller.signal, `${message.text}\n\nThe previous scene proposal was rejected before device delivery: ${error.message}. Return one corrected proposal that satisfies the tool schema. Do not mention this repair to the user.`);
        this.assertAdmissionCurrent(admission);
        normalized = normalizeProposal(message.requestId, parseAuthoringProposal(JSON.parse(functionCall) as unknown), observedNodeIds(admission.document));
      }
      if (controller.signal.aborted) return;
      if (normalized.mode === "explanation") {
        this.completed.add(message.requestId);
        this.send({ type: "session.explanation", requestId: message.requestId, proposalRequestIds: [], intentEpoch: admission.intentEpoch, text: normalized.explanation });
        return;
      }
      const proposalRequestIds = this.emitProposal(message.requestId, admission, normalized);
      this.pending.set(message.requestId, { requestId: message.requestId, intentEpoch: admission.intentEpoch, explanation: normalized.explanation, proposalRequestIds });
      this.completed.add(message.requestId);
      this.send({ type: "session.progress", requestId: message.requestId, status: "awaiting_installation", intentEpoch: admission.intentEpoch });
    } catch (error) {
      if (!controller.signal.aborted) this.error(message.requestId, error);
    } finally {
      this.active.delete(message.requestId);
    }
  }

  private async collectFunctionCall(message: UserRequest, admission: Snapshot, signal: AbortSignal, text: string): Promise<string> {
    let functionCall: string | undefined;
    for await (const event of this.model.stream({ requestId: message.requestId, text, selectionNodeIds: message.selection?.nodeIds ?? [], scene: admission.document, signal })) {
      if (signal.aborted) throw new ProtocolError("request cancelled", "cancelled");
      if (event.type === "text") this.send({ type: "session.model_text", requestId: message.requestId, delta: event.delta });
      if (event.type === "function_call") {
        if (event.name !== "propose_scene") throw new ProtocolError(`model called unsupported tool: ${event.name}`, "model_tool_rejected");
        if (functionCall !== undefined) throw new ProtocolError("model made more than one scene proposal", "model_tool_rejected");
        functionCall = event.arguments;
      }
    }
    if (!functionCall) throw new ProtocolError("model completed without a scene proposal", "model_tool_rejected");
    return functionCall;
  }

  receiveReceipt(receipt: SceneReceipt): void {
    const snapshot = this.requireSnapshot();
    if (receipt.protocolVersion !== PROTOCOL_VERSION || receipt.sceneId !== snapshot.sceneId) throw new ProtocolError("receipt protocol or scene mismatch", "receipt_rejected");
    if (receipt.revision < snapshot.revision) throw new ProtocolError("receipt revision is stale", "stale_receipt");
    // A receipt is evidence only. The following phone.snapshot updates the mirror document.
    this.snapshot = { ...snapshot, revision: receipt.revision };
    if (receipt.status === "installed") this.installedProposalIds.add(receipt.requestId);
    for (const pending of this.pending.values()) {
      if (!pending.proposalRequestIds.includes(receipt.requestId)) continue;
      if (receipt.status === "rejected") {
        this.pending.delete(pending.requestId);
        this.send({ type: "session.error", requestId: pending.requestId, code: "installation_rejected", message: "The device rejected the proposed scene change.", receipt: receipt as unknown as JsonObject });
        return;
      }
      if (!pending.proposalRequestIds.every((id) => receipt.requestId === id || this.wasInstalled(id))) return;
      if (snapshot.intentEpoch !== pending.intentEpoch || this.snapshot.intentEpoch !== pending.intentEpoch) {
        this.pending.delete(pending.requestId);
        return;
      }
      this.pending.delete(pending.requestId);
      this.send({ type: "session.explanation", requestId: pending.requestId, proposalRequestIds: pending.proposalRequestIds, intentEpoch: pending.intentEpoch, text: pending.explanation });
      return;
    }
  }

  receiveGenerationReceipt(receipt: GenerationReceipt): void {
    const snapshot = this.requireSnapshot();
    if (receipt.protocolVersion !== PROTOCOL_VERSION || receipt.sceneId !== snapshot.sceneId) throw new ProtocolError("generation receipt protocol or scene mismatch", "receipt_rejected");
    if (receipt.revision < snapshot.revision) throw new ProtocolError("generation receipt revision is stale", "stale_receipt");
    this.snapshot = { ...snapshot, revision: receipt.revision };
    if (receipt.status !== "rejected") return;
    const pending = [...this.pending.values()].find((item) => receipt.requestId.startsWith(`${item.requestId}:`));
    if (pending) this.pending.delete(pending.requestId);
    this.send({ type: "session.error", requestId: pending?.requestId ?? receipt.requestId, code: "generation_rejected", message: "The device rejected the generation scope.", receipt: receipt as unknown as JsonObject });
  }

  cancel(requestId: string): void { this.active.get(requestId)?.controller.abort(); }

  fence(sceneId: string, intentEpoch: number): void {
    const snapshot = this.requireSnapshot();
    if (sceneId !== snapshot.sceneId || intentEpoch < snapshot.intentEpoch) throw new ProtocolError("control carries a stale scene or epoch", "stale_control");
    for (const active of this.active.values()) active.controller.abort();
    this.pending.clear();
    // Native is the source of the new snapshot; do not fabricate a replacement epoch.
    this.snapshot = { ...snapshot, intentEpoch };
  }

  private installedProposalIds = new Set<string>();
  private wasInstalled(id: string): boolean { return this.installedProposalIds.has(id); }

  private emitProposal(userRequestId: string, admission: Snapshot, proposal: NormalizedProposal): string[] {
    this.assertAdmissionCurrent(admission);
    const requestIds: string[] = [];
    if (proposal.mode === "generation") {
      const generationId = stableGenerationId(userRequestId);
      const beginRequestId = `${userRequestId}:begin`;
      this.send({ type: "generation.begin", protocolVersion: PROTOCOL_VERSION, requestId: beginRequestId, sceneId: admission.sceneId, generationId, intentEpoch: admission.intentEpoch, initialBaseRevision: admission.revision, ...(proposal.scopeParentNodeId ? { scopeParentNodeId: proposal.scopeParentNodeId } : {}) });
      const batchRequestId = `${userRequestId}:batch:1`;
      const batch: JsonObject = { type: "generation.batch", protocolVersion: PROTOCOL_VERSION, requestId: batchRequestId, sceneId: admission.sceneId, generationId, intentEpoch: admission.intentEpoch, sequence: 1, operations: proposal.operations };
      batch.payloadHash = payloadHash(batch);
      this.send(batch);
      const finishRequestId = `${userRequestId}:finish`;
      this.send({ type: "generation.finish", protocolVersion: PROTOCOL_VERSION, requestId: finishRequestId, sceneId: admission.sceneId, generationId, intentEpoch: admission.intentEpoch, lastSequence: 1 });
      requestIds.push(batchRequestId);
      return requestIds;
    }
    const patchRequestId = `${userRequestId}:patch`;
    const patch: JsonObject = { type: "scene.patch", protocolVersion: PROTOCOL_VERSION, requestId: patchRequestId, sceneId: admission.sceneId, intentEpoch: admission.intentEpoch, baseRevision: admission.revision, operations: proposal.operations };
    patch.payloadHash = payloadHash(patch);
    this.send(patch);
    requestIds.push(patchRequestId);
    return requestIds;
  }

  private assertAdmissionCurrent(admission: Snapshot): void {
    const current = this.requireSnapshot();
    if (current.sceneId !== admission.sceneId || current.intentEpoch !== admission.intentEpoch || current.revision !== admission.revision) {
      throw new ProtocolError("model result is stale; it will not be retagged", "stale_model_result");
    }
  }

  private ensureHello(): void { if (!this.hello) throw new ProtocolError("session.hello is required first", "hello_required"); }
  private requireSnapshot(): Snapshot { this.ensureHello(); if (!this.snapshot) throw new ProtocolError("phone.snapshot is required", "snapshot_required"); return this.snapshot; }
  private send(message: JsonObject): void { this.sink.send(message); }
  private error(requestId: string, error: unknown): void {
    const known = error instanceof ProtocolError ? error : new ProtocolError(error instanceof Error ? error.message : "model request failed", "model_failed");
    this.send({ type: "session.error", requestId, code: known.code, message: known.message });
  }
}

function observedNodeIds(document: JsonObject): Set<string> {
  const nodes = document.nodes;
  if (!Array.isArray(nodes)) return new Set();
  const ids = new Set<string>();
  for (const node of nodes) if (isObject(node) && typeof node.nodeId === "string") ids.add(node.nodeId);
  return ids;
}

function stableGenerationId(requestId: string): string {
  return `generation_${createHash("sha256").update(requestId).digest("hex").slice(0, 24)}`;
}

function recordDiscardedProposal(requestId: string, reason: string, argumentsJson: string): void {
  // Audit-only local evidence. It is never sent to the native scene executor or replayed.
  const evidence = { event: "astra.discarded_proposal", requestId, reason, arguments: argumentsJson.slice(0, 16 * 1024), truncated: argumentsJson.length > 16 * 1024 };
  process.stderr.write(`${JSON.stringify(evidence)}\n`);
}
