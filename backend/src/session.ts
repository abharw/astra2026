import { createHash } from "node:crypto";
import { JsonObject, ProtocolError, isObject } from "./json.js";
import { ModelEvent, ModelTransport } from "./astra/client.js";
import { NormalizedProposal, normalizeProposal, parseAuthoringProposal, payloadHash } from "./normalizer.js";
import { GenerationReceipt, PhoneSnapshot, PROTOCOL_VERSION, SceneReceipt, SessionHello, UserRequest } from "./protocol.js";
import { DiagnosticLogger, safeError } from "./diagnostics.js";
import { SceneConversation, TurnInput } from "./astra/conversation-context.js";
import { AvailableAssetDetail } from "./asset-details.js";
import { IllustrationService, SessionIllustrations } from "./illustrations/jobs.js";
import { NodeLocalBounds, parseNodeLocalBounds } from "./node-local-bounds.js";

export interface SessionSink { send(message: JsonObject): void }

interface Snapshot {
  sceneId: string;
  revision: number;
  intentEpoch: number;
  document: JsonObject;
  availableAssetDetails: AvailableAssetDetail[];
  nodeLocalBounds: NodeLocalBounds[];
}

interface PendingProposal {
  requestId: string;
  intentEpoch: number;
  explanation: string;
  proposalRequestIds: string[];
  receiptTimer: ReturnType<typeof setTimeout>;
  startedAt: number;
  input: TurnInput;
  affectedNodeIds: Set<string>;
}

interface ActiveRun { controller: AbortController; startedAt: number; timedOut: boolean; deadline: ReturnType<typeof setTimeout> }

export interface SessionOptions { modelTimeoutMs?: number; receiptTimeoutMs?: number; logger?: DiagnosticLogger; sessionId?: string; illustrations?: IllustrationService; }
const DEFAULT_MODEL_TIMEOUT_MS = 45_000;
const DEFAULT_RECEIPT_TIMEOUT_MS = 30_000;

export class AstraSession {
  private hello?: SessionHello;
  private snapshot?: Snapshot;
  private snapshotSynchronized = false;
  private illustrations?: SessionIllustrations;
  private readonly illustrationService?: IllustrationService;
  private readonly active = new Map<string, ActiveRun>();
  private readonly pending = new Map<string, PendingProposal>();
  private readonly completed = new Set<string>();
  private readonly conversation = new SceneConversation();

  private readonly modelTimeoutMs: number;
  private readonly receiptTimeoutMs: number;
  private readonly logger?: DiagnosticLogger;
  private readonly sessionId?: string;
  constructor(private readonly model: ModelTransport, private sink: SessionSink, options: SessionOptions = {}) {
    this.modelTimeoutMs = options.modelTimeoutMs ?? DEFAULT_MODEL_TIMEOUT_MS;
    this.receiptTimeoutMs = options.receiptTimeoutMs ?? DEFAULT_RECEIPT_TIMEOUT_MS;
    this.logger = options.logger;
    this.sessionId = options.sessionId;
    this.illustrationService = options.illustrations;
  }

  acceptHello(hello: SessionHello): void {
    if (hello.protocolVersion !== PROTOCOL_VERSION || !hello.sceneSchemaVersions.includes(1) || !hello.geometrySemanticsVersions.includes(1)) {
      throw new ProtocolError("no compatible protocol/schema/geometry version", "unsupported_version");
    }
    if (this.hello && this.hello.sessionId !== hello.sessionId) throw new ProtocolError("connection cannot change sessionId", "session_mismatch");
    if (this.hello?.sceneId !== hello.sceneId) {
      this.dispose();
      this.completed.clear();
      this.installedProposalIds.clear();
    }
    this.hello = hello;
    if (this.illustrationService && hello.capabilities.includes("illustration.v1")) {
      this.illustrations = new SessionIllustrations(this.illustrationService, () => this.snapshotSynchronized ? this.snapshot : undefined, message => this.send(message), this.logger);
    }
    this.log("handshake_accepted", { sessionId: hello.sessionId });
    this.snapshot = undefined;
    this.snapshotSynchronized = false;
    this.send({ type: "session.accepted", protocolVersion: PROTOCOL_VERSION, sessionId: hello.sessionId, sceneSchemaVersion: 1, geometrySemanticsVersion: 1, illustrationEnabled: Boolean(this.illustrations) });
  }

  updateSnapshot(message: PhoneSnapshot): void {
    this.ensureHello();
    if (message.sceneId !== this.hello!.sceneId) throw new ProtocolError("snapshot sceneId differs from hello", "scene_mismatch");
    const previous = this.snapshot;
    if (previous && (message.intentEpoch < previous.intentEpoch || (message.intentEpoch === previous.intentEpoch && message.revision < previous.revision))) {
      throw new ProtocolError("snapshot cannot move epoch or revision backwards", "stale_snapshot");
    }
    this.snapshot = { sceneId: message.sceneId, revision: message.revision, intentEpoch: message.intentEpoch, document: message.document, availableAssetDetails: structuredClone(message.availableAssetDetails ?? []), nodeLocalBounds: parseNodeLocalBounds(message.nodeLocalBounds === undefined ? [] : message.nodeLocalBounds, message.document) };
    this.snapshotSynchronized = true;
    this.illustrations?.sceneChanged();
    this.log("snapshot_received", { revision: message.revision, epoch: message.intentEpoch, nodeCount: observedNodeIds(message.document).size });
  }

  async request(message: UserRequest): Promise<void> {
    this.ensureHello();
    const admission = this.requireSnapshot();
    if (!this.snapshotSynchronized) {
      this.error(message.requestId, new ProtocolError("Waiting for the device's accepted scene snapshot.", "scene_snapshot_pending"));
      return;
    }
    if (this.completed.has(message.requestId) || this.active.has(message.requestId)) { this.log("user_request_stale", { requestId: message.requestId, reason: "duplicate" }, "warn"); return; }
    const controller = new AbortController();
    const input: TurnInput = { userRequest: message.text, selectionNodeIds: [...(message.selection?.nodeIds ?? [])] };
    const admittedIllustrations = this.illustrations?.recent() ?? [];
    const startedAt = Date.now();
    const run: ActiveRun = { controller, startedAt, timedOut: false, deadline: undefined as unknown as ReturnType<typeof setTimeout> };
    run.deadline = setTimeout(() => { run.timedOut = true; controller.abort(); }, this.modelTimeoutMs);
    run.deadline.unref();
    this.active.set(message.requestId, run);
    this.log("user_request_admitted", { requestId: message.requestId, revision: admission.revision, epoch: admission.intentEpoch });
    this.send({ type: "session.progress", requestId: message.requestId, status: "thinking", intentEpoch: admission.intentEpoch });
    let deliveryStarted = false;
    try {
      let functionCall = await this.collectFunctionCall(message, admission, controller.signal, message.text, admittedIllustrations);
      if (controller.signal.aborted) return;
      this.assertAdmissionCurrent(admission);
      let normalized: NormalizedProposal;
      try {
        this.send({ type: "session.progress", requestId: message.requestId, status: "processing", intentEpoch: admission.intentEpoch });
        normalized = normalizeProposal(message.requestId, parseAuthoringProposal(JSON.parse(functionCall) as unknown), observedNodeIds(admission.document), observedGeometryIds(admission.document), observedNodes(admission.document), admission.availableAssetDetails, { flowEnabled: this.hello!.capabilities.includes("flow.v1"), observedGeometries: observedGeometries(admission.document), observedRelationships: Array.isArray(admission.document.relationships) ? admission.document.relationships.filter(isObject) : [] });
      } catch (error) {
        if (!(error instanceof ProtocolError) || error.code !== "proposal_rejected") throw error;
        this.log("normalize_repair", { requestId: message.requestId, reason: error.code, safeError: safeError(error) }, "warn");
        this.send({ type: "session.progress", requestId: message.requestId, status: "repairing_proposal", intentEpoch: admission.intentEpoch });
        functionCall = await this.collectFunctionCall(message, admission, controller.signal, `${message.text}\n\nThe previous scene proposal was rejected before device delivery: ${error.message}. Return one corrected proposal that satisfies the tool schema. Do not mention this repair to the user.`, admittedIllustrations);
        this.assertAdmissionCurrent(admission);
        normalized = normalizeProposal(message.requestId, parseAuthoringProposal(JSON.parse(functionCall) as unknown), observedNodeIds(admission.document), observedGeometryIds(admission.document), observedNodes(admission.document), admission.availableAssetDetails, { flowEnabled: this.hello!.capabilities.includes("flow.v1"), observedGeometries: observedGeometries(admission.document), observedRelationships: Array.isArray(admission.document.relationships) ? admission.document.relationships.filter(isObject) : [] });
      }
      if (controller.signal.aborted) return;
      if (normalized.illustration) {
        if (!this.illustrations) throw new ProtocolError("This client does not support illustration generation.", "illustration_unavailable");
        if (!this.snapshotSynchronized) throw new ProtocolError("Waiting for the accepted scene snapshot before generating an illustration.", "illustration_scene_pending");
        if (normalized.illustration.sourceArtifactId && !admittedIllustrations.some(item => item.artifactId === normalized.illustration!.sourceArtifactId)) throw new ProtocolError("The reference illustration was not available when this request began.", "illustration_source_unavailable");
        this.illustrations.start(message.requestId, admission, normalized.illustration);
      }
      if (normalized.mode === "explanation") {
        this.conversation.append(input, { status: "answered", explanation: normalized.explanation, affectedNodeIds: [] });
        this.completed.add(message.requestId);
        this.log("explanation_sent", { requestId: message.requestId, durationMs: Date.now() - startedAt });
        this.send({ type: "session.explanation", requestId: message.requestId, proposalRequestIds: [], intentEpoch: admission.intentEpoch, text: normalized.explanation });
        return;
      }
      deliveryStarted = true;
      const proposalRequestIds = this.emitProposal(message.requestId, admission, normalized);
      const receiptTimer = setTimeout(() => this.expireReceipt(message.requestId, admission.intentEpoch), this.receiptTimeoutMs);
      receiptTimer.unref();
      this.pending.set(message.requestId, { requestId: message.requestId, intentEpoch: admission.intentEpoch, explanation: normalized.explanation, proposalRequestIds, receiptTimer, startedAt, input, affectedNodeIds: new Set() });
      this.completed.add(message.requestId);
      this.send({ type: "session.progress", requestId: message.requestId, status: "awaiting_installation", intentEpoch: admission.intentEpoch });
    } catch (error) {
      // Before emitProposal there is no device mutation. Cancellation and stale
      // work are not conversation outcomes, and must not become installed history.
      if (!deliveryStarted && !controller.signal.aborted && !(error instanceof ProtocolError && error.code === "stale_model_result")) {
        this.conversation.append(input, { status: "failed", explanation: "The request failed before a scene change was delivered.", affectedNodeIds: [] });
      }
      if (run.timedOut) this.error(message.requestId, new ProtocolError("The model took too long to respond.", "model_timeout"));
      else if (!controller.signal.aborted) this.error(message.requestId, error);
    } finally {
      clearTimeout(run.deadline);
      this.active.delete(message.requestId);
    }
  }

  private async collectFunctionCall(message: UserRequest, admission: Snapshot, signal: AbortSignal, text: string, recentIllustrations: import("./astra/client.js").RecentIllustration[]): Promise<string> {
    let functionCall: string | undefined;
    const streamController = new AbortController();
    const forwardAbort = () => streamController.abort();
    signal.addEventListener("abort", forwardAbort, { once: true });
    if (signal.aborted) streamController.abort();
    const iterator = this.model.stream({ requestId: message.requestId, text, selectionNodeIds: message.selection?.nodeIds ?? [], scene: admission.document, illustrationEnabled: Boolean(this.illustrations), flowEnabled: this.hello!.capabilities.includes("flow.v1"), nodeLocalBounds: this.hello!.capabilities.includes("flow.v1") ? structuredClone(admission.nodeLocalBounds) : undefined, recentIllustrations, availableAssetDetails: admission.availableAssetDetails, recentTurns: this.conversation.context(observedNodeIds(admission.document)), signal: streamController.signal })[Symbol.asyncIterator]();
    this.log("astra_fetch_start", { requestId: message.requestId });
    let sawFirstEvent = false;
    let completed = false;
    try {
      while (true) {
        const next = await nextBefore(iterator, signal);
        if (next.done) break;
        const event = next.value;
        if (!sawFirstEvent) { sawFirstEvent = true; this.log("astra_first_event", { requestId: message.requestId, durationMs: Date.now() - this.active.get(message.requestId)!.startedAt }); }
        if (signal.aborted) throw new ProtocolError("request cancelled", "cancelled");
        if (event.type === "text") this.send({ type: "session.model_text", requestId: message.requestId, delta: event.delta });
        if (event.type === "progress") this.send({ type: "session.progress", requestId: message.requestId, status: event.stage, intentEpoch: admission.intentEpoch });
        if (event.type === "done") { completed = true; break; }
        if (event.type === "function_call") {
          if (event.name !== "propose_scene") throw new ProtocolError(`model called unsupported tool: ${event.name}`, "model_tool_rejected");
          if (functionCall !== undefined) throw new ProtocolError("model made more than one scene proposal", "model_tool_rejected");
          functionCall = event.arguments;
          this.log("astra_function_arguments_done", { requestId: message.requestId, bytes: Buffer.byteLength(event.arguments, "utf8") });
        }
      }
    } finally {
      // response.completed can arrive before the HTTP body EOF. Abort our private
      // stream signal and close the iterator even on success so its reader is released.
      await closeIterator(iterator);
      streamController.abort();
      signal.removeEventListener("abort", forwardAbort);
    }
    if (!completed) throw new ProtocolError("model stream ended before completion", "model_incomplete");
    if (!functionCall) throw new ProtocolError("model completed without a scene proposal", "model_tool_rejected");
    return functionCall;
  }

  receiveReceipt(receipt: SceneReceipt): void {
    this.log("receipt_received", { requestId: receipt.requestId, status: receipt.status, revision: receipt.revision });
    const snapshot = this.requireSnapshot();
    if (receipt.protocolVersion !== PROTOCOL_VERSION || receipt.sceneId !== snapshot.sceneId) throw new ProtocolError("receipt protocol or scene mismatch", "receipt_rejected");
    if (receipt.revision < snapshot.revision) throw new ProtocolError("receipt revision is stale", "stale_receipt");
    // A receipt is evidence only. The following phone.snapshot updates the mirror document.
    this.snapshot = { ...snapshot, revision: receipt.revision };
    if (receipt.revision !== snapshot.revision) this.snapshotSynchronized = false;
    this.illustrations?.sceneChanged();
    if (receipt.status === "installed") this.installedProposalIds.add(receipt.requestId);
    for (const pending of this.pending.values()) {
      if (!pending.proposalRequestIds.includes(receipt.requestId)) continue;
      if (receipt.status === "rejected") {
        this.clearPending(pending);
        this.conversation.append(pending.input, { status: "failed", explanation: "The device rejected the proposed scene change.", affectedNodeIds: [] });
        this.send({ type: "session.error", requestId: pending.requestId, code: "installation_rejected", message: "The device rejected the proposed scene change.", receipt: receipt as unknown as JsonObject });
        return;
      }
      for (const id of receipt.affectedNodeIds) pending.affectedNodeIds.add(id);
      if (!pending.proposalRequestIds.every((id) => receipt.requestId === id || this.wasInstalled(id))) return;
      if (snapshot.intentEpoch !== pending.intentEpoch || this.snapshot.intentEpoch !== pending.intentEpoch) {
        this.clearPending(pending);
        return;
      }
      this.clearPending(pending);
      this.conversation.append(pending.input, { status: "installed", explanation: pending.explanation, affectedNodeIds: [...pending.affectedNodeIds] });
      this.log("explanation_sent", { requestId: pending.requestId, durationMs: Date.now() - pending.startedAt });
      this.send({ type: "session.explanation", requestId: pending.requestId, proposalRequestIds: pending.proposalRequestIds, intentEpoch: pending.intentEpoch, text: pending.explanation });
      return;
    }
  }

  receiveGenerationReceipt(receipt: GenerationReceipt): void {
    this.log("generation_receipt_received", { requestId: receipt.requestId, status: receipt.status, revision: receipt.revision });
    const snapshot = this.requireSnapshot();
    if (receipt.protocolVersion !== PROTOCOL_VERSION || receipt.sceneId !== snapshot.sceneId) throw new ProtocolError("generation receipt protocol or scene mismatch", "receipt_rejected");
    if (receipt.revision < snapshot.revision) throw new ProtocolError("generation receipt revision is stale", "stale_receipt");
    this.snapshot = { ...snapshot, revision: receipt.revision };
    if (receipt.revision !== snapshot.revision) this.snapshotSynchronized = false;
    this.illustrations?.sceneChanged();
    if (receipt.status !== "rejected") return;
    const pending = [...this.pending.values()].find((item) => receipt.requestId.startsWith(`${item.requestId}:`));
    if (pending) {
      this.clearPending(pending);
      this.conversation.append(pending.input, { status: "failed", explanation: "The device rejected the generation scope.", affectedNodeIds: [] });
    }
    this.send({ type: "session.error", requestId: pending?.requestId ?? receipt.requestId, code: "generation_rejected", message: "The device rejected the generation scope.", receipt: receipt as unknown as JsonObject });
  }

  cancel(requestId: string): void {
    this.active.get(requestId)?.controller.abort();
    const pending = this.pending.get(requestId);
    if (pending) this.clearPending(pending);
    this.log("user_request_cancel", { requestId });
  }

  cancelIllustration(jobId: string): void { this.illustrations?.cancel(jobId); }
  retryIllustration(jobId: string): void {
    if (!this.illustrations) throw new ProtocolError("Illustrations are unavailable.", "illustration_unavailable");
    this.illustrations.retry(jobId);
  }

  dispose(): void {
    this.illustrations?.dispose();
    this.illustrations = undefined;
    for (const active of this.active.values()) { clearTimeout(active.deadline); active.controller.abort(); }
    this.active.clear();
    for (const pending of this.pending.values()) this.clearPending(pending);
    this.conversation.clear();
  }

  fence(sceneId: string, intentEpoch: number): void {
    const snapshot = this.requireSnapshot();
    if (sceneId !== snapshot.sceneId || intentEpoch < snapshot.intentEpoch) throw new ProtocolError("control carries a stale scene or epoch", "stale_control");
    for (const active of this.active.values()) active.controller.abort();
    for (const pending of this.pending.values()) this.clearPending(pending);
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
      this.log("outgoing_batch", { requestId: userRequestId, bytes: Buffer.byteLength(JSON.stringify(batch), "utf8") });
      const finishRequestId = `${userRequestId}:finish`;
      this.send({ type: "generation.finish", protocolVersion: PROTOCOL_VERSION, requestId: finishRequestId, sceneId: admission.sceneId, generationId, intentEpoch: admission.intentEpoch, lastSequence: 1 });
      requestIds.push(batchRequestId);
      return requestIds;
    }
    const patchRequestId = `${userRequestId}:patch`;
    const patch: JsonObject = { type: "scene.patch", protocolVersion: PROTOCOL_VERSION, requestId: patchRequestId, sceneId: admission.sceneId, intentEpoch: admission.intentEpoch, baseRevision: admission.revision, operations: proposal.operations };
    patch.payloadHash = payloadHash(patch);
    this.send(patch);
    this.log("outgoing_batch", { requestId: userRequestId, bytes: Buffer.byteLength(JSON.stringify(patch), "utf8") });
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
    this.log("request_error", { requestId, reason: known.code, safeError: safeError(error) }, "warn");
  }
  private clearPending(pending: PendingProposal): void { clearTimeout(pending.receiptTimer); this.pending.delete(pending.requestId); }
  private expireReceipt(requestId: string, intentEpoch: number): void {
    const pending = this.pending.get(requestId);
    if (!pending || pending.intentEpoch !== intentEpoch || this.snapshot?.intentEpoch !== intentEpoch) return;
    this.clearPending(pending);
    this.send({ type: "session.error", requestId, code: "receipt_timeout", message: "The device did not confirm the scene change in time." });
    this.log("receipt_timeout", { requestId, durationMs: this.receiptTimeoutMs }, "warn");
  }
  private log(event: string, fields: Record<string, boolean | number | string | undefined> = {}, level: "debug" | "info" | "warn" | "error" = "info"): void { this.logger?.log("session", event, { sessionId: this.hello?.sessionId ?? this.sessionId, ...fields }, level); }
}

function observedNodeIds(document: JsonObject): Set<string> {
  const nodes = document.nodes;
  if (!Array.isArray(nodes)) return new Set();
  const ids = new Set<string>();
  for (const node of nodes) if (isObject(node) && typeof node.nodeId === "string") ids.add(node.nodeId);
  return ids;
}

function observedNodes(document: JsonObject): Map<string, JsonObject> {
  if (!Array.isArray(document.nodes)) return new Map();
  return new Map(document.nodes.filter(isObject).filter((node) => typeof node.nodeId === "string").map((node) => [node.nodeId as string, node]));
}

function stableGenerationId(requestId: string): string {
  return `generation_${createHash("sha256").update(requestId).digest("hex").slice(0, 24)}`;
}

async function nextBefore<T>(iterator: AsyncIterator<T>, signal: AbortSignal): Promise<IteratorResult<T>> {
  if (signal.aborted) { closeIteratorWithoutWaiting(iterator); throw new ProtocolError("request cancelled", "cancelled"); }
  let rejectAbort: ((error: ProtocolError) => void) | undefined;
  const onAbort = () => { closeIteratorWithoutWaiting(iterator); rejectAbort?.(new ProtocolError("request cancelled", "cancelled")); };
  const aborted = new Promise<never>((_, reject) => { rejectAbort = reject; signal.addEventListener("abort", onAbort, { once: true }); });
  try { return await Promise.race([iterator.next(), aborted]); }
  finally { signal.removeEventListener("abort", onAbort); }
}

async function closeIterator(iterator: AsyncIterator<unknown>): Promise<void> {
  const closing = iterator.return?.();
  if (!closing) return;
  // A compliant generator returns promptly. Bound a broken adapter without leaving
  // its eventual rejection unobserved; the private controller below then aborts it.
  const handled = closing.catch(() => undefined);
  let timer: ReturnType<typeof setTimeout> | undefined;
  try { await Promise.race([handled, new Promise<void>((resolve) => { timer = setTimeout(resolve, 100); timer.unref(); })]); }
  finally { if (timer) clearTimeout(timer); }
}

function closeIteratorWithoutWaiting(iterator: AsyncIterator<unknown>): void {
  const closing = iterator.return?.();
  if (closing) void closing.catch(() => undefined);
}

function observedGeometryIds(document: JsonObject): Set<string> {
  const geometries = document.geometryDefinitions;
  if (!Array.isArray(geometries)) return new Set();
  return new Set(geometries.flatMap((value) => isObject(value) && typeof value.geometryId === "string" ? [value.geometryId] : []));
}

function observedGeometries(document: JsonObject): Map<string, JsonObject> {
  if (!Array.isArray(document.geometryDefinitions)) return new Map();
  return new Map(document.geometryDefinitions.filter(isObject).filter(geometry => typeof geometry.geometryId === "string").map(geometry => [geometry.geometryId as string, geometry]));
}
