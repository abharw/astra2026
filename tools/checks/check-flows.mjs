#!/usr/bin/env node

// Live authoring acceptance. Every install/Undo uses the production Swift reducer.
// Synthetic fixture snapshots are never described as native rendering or physical AR.
import { spawn } from "node:child_process";
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { isAbsolute, relative, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../../", import.meta.url));
const require = createRequire(import.meta.url);
const stages = ["create", "reverse", "transform", "hide", "delete", "undo"];
const help = `Usage: node tools/checks/check-flows.mjs [options]

--url URL          Running backend (default env or .local/dev-session.json).
--fixtures LIST    rack,lamp (default both).
--through STAGE    create|reverse|transform|hide|delete|undo (default undo).
--scenelab PATH    Built SceneLab with reducer command.
                   Default .local/build/flow-check/debug/SceneLab.
--out DIRECTORY   Outputs beneath .local/ only (default timestamped).
--timeout-ms N    Each live model turn deadline, 10000..180000 (default 90000).
--prepare-only    Validate and export fixtures using real Swift; no network calls.
--help            No credentials, build, subprocess, or network access.

Build first:
  swift build --package-path tools --scratch-path .local/build/flow-check --product SceneLab
Run:
  node tools/checks/check-flows.mjs --prepare-only
  node tools/checks/check-flows.mjs --through create
  node tools/checks/check-flows.mjs --out .local/flow-acceptance/live

SESSION_ACCESS_TOKEN / ASTRA_SESSION_TOKEN / saved config supplies auth silently.
Each fixture keeps one WebSocket and one real Swift SceneState throughout.
The five authoring turns use the real model; Undo is the native host operation.
PNG/image capabilities are not advertised. No mocked reducer or production routes.
No nodeLocalBounds are supplied: these headless fixtures have no renderer measurements.
Receipt/document checks do not prove curve geometry, animation, visual quality,
physical-device frame performance, or AR anchoring. Accepted documents are exported.
`;
function check(condition, code) { if (!condition) throw Object.assign(new Error(code), { checkCode: code }); }
function safeCode(value) { return typeof value === "string" && /^[a-zA-Z0-9_.:-]{1,100}$/.test(value) ? value : "unclassified"; }
function checksum(bytes) { return createHash("sha256").update(bytes).digest("hex"); }
function canonical(value) {
  if (Array.isArray(value)) return value.map(canonical);
  if (value && typeof value === "object") return Object.fromEntries(Object.entries(value).sort(([a], [b]) => a.localeCompare(b)).map(([key, child]) => [key, canonical(child)]));
  return value;
}
function equal(a, b) { return JSON.stringify(canonical(a)) === JSON.stringify(canonical(b)); }
function digest(value) { return checksum(JSON.stringify(canonical(value))); }
function parseOptions(args) {
  const result = { fixtures: ["rack", "lamp"], through: "undo", timeoutMS: 90_000, prepareOnly: false };
  for (let index = 0; index < args.length; index += 1) {
    const name = args[index];
    if (name === "--prepare-only") { result.prepareOnly = true; continue; }
    check(["--url", "--fixtures", "--through", "--scenelab", "--out", "--timeout-ms"].includes(name), "invalid_arguments_use_help");
    const value = args[++index];
    check(typeof value === "string" && !value.startsWith("--"), "missing_argument_value");
    if (name === "--url") result.url = value;
    if (name === "--fixtures") result.fixtures = [...new Set(value.split(","))];
    if (name === "--through") result.through = value;
    if (name === "--scenelab") result.binary = resolve(root, value);
    if (name === "--out") result.out = resolve(root, value);
    if (name === "--timeout-ms") result.timeoutMS = Number(value);
  }
  check(result.fixtures.length > 0 && result.fixtures.every(value => ["rack", "lamp"].includes(value)), "invalid_fixtures");
  check(stages.includes(result.through), "invalid_through_stage");
  check(Number.isSafeInteger(result.timeoutMS) && result.timeoutMS >= 10_000 && result.timeoutMS <= 180_000, "invalid_timeout");
  result.binary ??= resolve(root, ".local/build/flow-check/debug/SceneLab");
  result.out ??= resolve(root, `.local/flow-acceptance/${new Date().toISOString().replaceAll(":", "-")}`);
  const subpath = relative(resolve(root, ".local"), result.out);
  check(subpath && !subpath.startsWith("..") && !isAbsolute(subpath), "output_must_be_beneath_local");
  return result;
}

class ReducerBridge {
  constructor(binary) {
    this.pending = new Map(); this.buffer = Buffer.alloc(0);
    // The reducer needs no service/provider secrets. Never inherit those variables.
    this.child = spawn(binary, ["reducer"], { cwd: root, env: { PATH: process.env.PATH ?? "/usr/bin:/bin", LANG: "en_US.UTF-8" }, stdio: ["pipe", "pipe", "pipe"] });
    this.child.stdout.on("data", chunk => {
      try {
        this.buffer = Buffer.concat([this.buffer, chunk]);
        let newline;
        while ((newline = this.buffer.indexOf(10)) !== -1) {
          check(newline <= 1024 * 1024, "reducer_response_too_large");
          const line = this.buffer.subarray(0, newline); this.buffer = this.buffer.subarray(newline + 1);
          const reply = JSON.parse(line.toString("utf8"));
          const pending = this.pending.get(reply.id);
          check(pending, "unexpected_reducer_response");
          this.pending.delete(reply.id); clearTimeout(pending.timer);
          if (reply.ok !== true) pending.reject(Object.assign(new Error(), { checkCode: `reducer:${safeCode(reply.code)}` }));
          else pending.resolve(reply);
        }
        check(this.buffer.length <= 1024 * 1024, "reducer_response_too_large");
      } catch (error) { this.fail(error.checkCode ?? "reducer_invalid_json"); }
    });
    this.child.stderr.on("data", () => { this.stderrObserved = true; });
    this.child.on("error", () => this.fail("reducer_process_start_failed"));
    this.child.on("exit", () => { if (!this.closing) this.fail("reducer_exited_early"); });
    this.child.stdin.on("error", () => this.fail("reducer_stdin_failed"));
  }
  fail(code) {
    this.failureCode ??= code;
    for (const pending of this.pending.values()) { clearTimeout(pending.timer); pending.reject(Object.assign(new Error(), { checkCode: this.failureCode })); }
    this.pending.clear();
  }
  request(command, fields = {}, id = randomUUID()) {
    check(!this.failureCode, this.failureCode ?? "reducer_failed");
    const bytes = Buffer.from(`${JSON.stringify({ id, command, ...fields })}\n`);
    check(bytes.length <= 1024 * 1024, "reducer_request_too_large");
    return new Promise((resolvePromise, reject) => {
      const timer = setTimeout(() => { this.pending.delete(id); reject(Object.assign(new Error(), { checkCode: "reducer_timeout" })); this.close(); }, 10_000);
      this.pending.set(id, { resolve: resolvePromise, reject, timer });
      this.child.stdin.write(bytes);
    });
  }
  close() {
    if (this.closing) return;
    this.closing = true; this.fail("reducer_closed"); this.child.stdin.end();
    const force = setTimeout(() => this.child.kill("SIGKILL"), 1_000); force.unref();
    this.child.once("exit", () => clearTimeout(force));
  }
}

async function fixtures() {
  const rackPath = "assets/server-rack/scene.json";
  const bytes = await readFile(resolve(root, rackPath)), rack = JSON.parse(bytes);
  const geometryIDs = ["beam-x", "fan-hub"];
  check(geometryIDs.every(id => rack.geometryDefinitions.some(value => value.geometryId === id)), "fixture_geometry_missing");
  const lamp = { schemaVersion: 1, geometrySemanticsVersion: 1, documentId: "synthetic-lamp-flow-acceptance",
    geometryDefinitions: rack.geometryDefinitions.filter(value => geometryIDs.includes(value.geometryId)),
    materials: [{ materialId: "lamp-white", baseColorLinear: [0.8, 0.8, 0.75, 1], metallic: 0.1, roughness: 0.5 }],
    nodes: [
      { nodeId: "lamp", semantic: { name: "Generic teaching desk lamp", role: "assembly", description: "Synthetic, schematic lamp; no manufacturer or hidden circuit is claimed." }, transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] } },
      { nodeId: "lamp.base", parentId: "lamp", geometryId: "beam-x", materialId: "lamp-white", semantic: { name: "Lamp base and switch", role: "power-input" }, transform: { translation: [0, 0.02, 0], rotation: [0, 0, 0, 1], scale: [0.3, 1, 2] } },
      { nodeId: "lamp.bulb", parentId: "lamp", geometryId: "fan-hub", materialId: "lamp-white", semantic: { name: "Lamp light source", role: "light-source" }, transform: { translation: [0.08, 0.25, 0], rotation: [0, 0, 0, 1], scale: [2, 2, 2] } }
    ].map(node => ({ ...node, isVisible: true, provenance: { origin: "authored", factualSupport: "illustrative", sourceRefs: [] } })),
    relationships: [{ relationshipId: "lamp.power", kind: "electricalSupply", sourceNodeId: "lamp.base", targetNodeId: "lamp.bulb", description: "Conceptual energy delivery; not an electrical simulation." }] };
  return {
    rack: { document: rack, path: rackPath, fixtureSHA256: checksum(bytes), sourceNodeId: "server-1-cpu-1", targetNodeId: "server-1-fan-wall", label: "Heat transfer" },
    lamp: { document: lamp, path: "inline:synthetic-lamp-with-authored-primitive-geometry", fixtureSHA256: digest(lamp), sourceNodeId: "lamp.base", targetNodeId: "lamp.bulb", label: "Electrical energy" }
  };
}
async function savedConnection(options) {
  let saved = {};
  try { saved = JSON.parse(await readFile(resolve(root, ".local/dev-session.json"), "utf8")); }
  catch (error) { check(error.code === "ENOENT", "invalid_saved_connection"); }
  const url = new URL(options.url ?? process.env.ASTRA_SESSION_BASE_URL ?? saved.url ?? "http://127.0.0.1:8787");
  if (url.protocol === "http:") url.protocol = "ws:";
  if (url.protocol === "https:") url.protocol = "wss:";
  check(["ws:", "wss:"].includes(url.protocol) && !url.username && !url.password, "invalid_backend_url");
  url.pathname = "/session"; url.search = ""; url.hash = "";
  return { url, token: process.env.ASTRA_SESSION_TOKEN ?? process.env.SESSION_ACCESS_TOKEN ?? saved.token };
}

class LiveScene {
  constructor(bridge, initial, connection, options) {
    this.bridge = bridge; this.state = initial; this.options = options; this.queue = Promise.resolve();
    const WebSocket = require("../../backend/node_modules/ws");
    this.socket = new WebSocket(connection.url, { handshakeTimeout: 15_000, maxPayload: 256 * 1024 });
    this.socket.on("error", () => this.fail("websocket_transport_failed"));
    this.socket.on("close", () => { if (!this.closing) this.fail("websocket_closed_early"); });
    this.socket.on("message", raw => {
      this.queue = this.queue.then(() => this.receive(raw)).catch(error => this.fail(error.checkCode ?? "server_message_failed"));
    });
    this.accepted = new Promise((resolveAccepted, reject) => {
      this.handshake = { resolve: resolveAccepted, reject, timer: setTimeout(() => this.fail("handshake_timeout"), 15_000) };
      this.socket.once("open", () => this.send({ type: "session.hello", protocolVersion: 1, sessionId: randomUUID(),
        sceneId: initial.sceneId, revision: initial.revision, intentEpoch: initial.intentEpoch,
        sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: initial.capabilities,
        ...(connection.token ? { authToken: connection.token } : {}) }));
    });
  }
  fail(code) {
    this.failureCode ??= code;
    for (const pending of [this.handshake, this.active]) {
      if (pending) { clearTimeout(pending.timer); pending.reject(Object.assign(new Error(), { checkCode: this.failureCode })); }
    }
    this.handshake = undefined; this.active = undefined;
  }
  send(message) { check(this.socket.readyState === 1, "websocket_not_open"); this.socket.send(JSON.stringify(message)); }
  snapshot() { this.send({ type: "phone.snapshot", sceneId: this.state.sceneId, revision: this.state.revision, intentEpoch: this.state.intentEpoch, document: this.state.document }); }
  async receive(raw) {
    check(!this.failureCode, this.failureCode ?? "websocket_failed");
    const message = JSON.parse(raw.toString("utf8"));
    if (message.type === "session.accepted") {
      check(this.handshake && message.protocolVersion === 1, "unexpected_handshake");
      clearTimeout(this.handshake.timer); this.handshake.resolve(); this.handshake = undefined; return;
    }
    check(message.type !== "session.error", `session_error:${safeCode(message.code)}`);
    check(message.type !== "illustration.state", "unexpected_illustration_job");
    if (["generation.begin", "generation.batch", "generation.finish", "scene.patch"].includes(message.type)) {
      const active = this.active;
      check(active && typeof message.requestId === "string" && message.requestId.startsWith(`${active.record.requestId}:`), "uncorrelated_scene_proposal");
      check(message.sceneId === this.state.sceneId && message.intentEpoch === this.state.intentEpoch, "scene_proposal_admission_mismatch");
      const before = this.state.revision;
      const applied = await this.bridge.request("apply", { message });
      check(applied.receipt?.requestId === message.requestId && applied.receipt.sceneId === this.state.sceneId, "swift_receipt_correlation_mismatch");
      this.state = applied;
      active.record.receipts.push(applied.receipt);
      active.record.proposals.push({ type: message.type, requestId: message.requestId, payloadHash: message.payloadHash ?? null,
        operationCount: message.operations?.length ?? 0, previousRevision: before, resultingRevision: applied.revision });
      this.send(applied.receipt); this.snapshot();
      check(applied.receipt.status !== "rejected", `swift_rejected:${safeCode(applied.receipt.rejection?.code)}`);
    } else if (message.type === "session.explanation") {
      const active = this.active;
      check(active && message.requestId === active.record.requestId && message.intentEpoch === this.state.intentEpoch, "uncorrelated_explanation");
      check(active.record.receipts.some(receipt => receipt.status === "installed"), "model_explained_without_installed_scene_change");
      const installedIds = [...new Set(active.record.receipts.filter(receipt => receipt.status === "installed").map(receipt => receipt.requestId))].sort();
      check(Array.isArray(message.proposalRequestIds) && message.proposalRequestIds.length > 0 && equal([...message.proposalRequestIds].sort(), installedIds), "explanation_installed_proposal_set_mismatch");
      if (active.record.proposals.some(proposal => proposal.type === "generation.begin")) {
        check(active.record.proposals.some(proposal => proposal.type === "generation.finish") && active.record.receipts.some(receipt => receipt.type === "generation.receipt" && receipt.status === "completed"), "generation_scope_not_completed");
      }
      active.record.explanationCharacters = typeof message.text === "string" ? message.text.length : 0;
      active.record.elapsedMS = Math.round(performance.now() - active.started);
      clearTimeout(active.timer); this.active = undefined; active.resolve(this.state);
    }
  }
  async request(record, text, selection) {
    check(!this.active && !this.failureCode, this.failureCode ?? "request_already_active");
    this.state = await this.bridge.request("advanceIntent");
    this.snapshot();
    record.sceneId = this.state.sceneId; record.sourceRevision = this.state.revision; record.intentEpoch = this.state.intentEpoch;
    record.selectedNodeIds = selection; record.receipts = []; record.proposals = []; record.authoring = "live-model-propose_scene";
    const result = new Promise((resolveRequest, reject) => {
      this.active = { record, resolve: resolveRequest, reject, started: performance.now(), timer: setTimeout(() => {
        if (this.socket.readyState === 1) this.send({ type: "session.cancel", requestId: record.requestId });
        this.fail("model_turn_timeout");
      }, this.options.timeoutMS) };
    });
    this.send({ type: "user.request", requestId: record.requestId, text, selection: { nodeIds: selection } });
    return result;
  }
  async synchronizeTransport() {
    const payload = randomUUID();
    await new Promise((done, reject) => {
      const onPong = data => { if (data.toString() === payload) { clearTimeout(timer); this.socket.off("pong", onPong); done(); } };
      const timer = setTimeout(() => { this.socket.off("pong", onPong); reject(Object.assign(new Error(), { checkCode: "final_transport_sync_timeout" })); }, 5_000);
      this.socket.on("pong", onPong); this.socket.ping(payload);
    });
    await this.queue;
    check(!this.failureCode, this.failureCode ?? "websocket_failed");
  }
  close() { this.closing = true; this.fail("client_closed"); this.socket.terminate(); }
}

function flows(document) {
  const definitions = new Map(document.geometryDefinitions.map(value => [value.geometryId, value.recipe]));
  return document.nodes.flatMap(node => definitions.get(node.geometryId)?.kind === "flow" ? [{ node, recipe: definitions.get(node.geometryId) }] : []);
}
function node(document, id) { const result = document.nodes.find(value => value.nodeId === id); check(result, "expected_node_missing"); return result; }
function unchangedStructuralNodes(before, after, except = []) {
  for (const prior of before.nodes) if (!except.includes(prior.nodeId)) check(equal(prior, node(after, prior.nodeId)), "unrequested_structural_node_changed");
}
function unchangedSceneContext(before, after, allowedGeometryIDs = []) {
  for (const prior of before.geometryDefinitions) {
    if (!allowedGeometryIDs.includes(prior.geometryId)) {
      check(equal(prior, after.geometryDefinitions.find(value => value.geometryId === prior.geometryId)), "unrequested_geometry_definition_changed");
    }
  }
  for (const prior of before.materials) check(equal(prior, after.materials.find(value => value.materialId === prior.materialId)), "unrequested_material_changed");
  check(equal(before.relationships, after.relationships), "unrequested_relationship_changed");
  const metadata = document => Object.fromEntries(Object.entries(document).filter(([key]) => !["nodes", "geometryDefinitions", "materials", "relationships"].includes(key)));
  check(equal(metadata(before), metadata(after)), "scene_metadata_changed");
}
async function saveScene(options, name, stage, document) {
  const path = resolve(options.out, `${name}-${stage}.scene.json`);
  await writeFile(path, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 });
  return relative(root, path);
}

async function exerciseFixture(name, fixture, connection, options, report) {
  const bridge = new ReducerBridge(options.binary);
  let client;
  const item = { fixture: name, source: fixture.path, fixtureSHA256: fixture.fixtureSHA256, status: "running", turns: [] };
  report.fixtures.push(item);
  try {
    const initial = await bridge.request("initialize", { document: fixture.document, sceneId: `flow-check-${randomUUID()}` });
    check(initial.capabilities?.includes("flow.v1"), "compiled_reducer_does_not_support_flow");
    item.initialSceneSHA256 = digest(initial.document);
    item.initialScenePath = await saveScene(options, name, "initial", initial.document);
    if (options.prepareOnly) { item.status = "validated-offline"; return; }
    client = new LiveScene(bridge, initial, connection, options); await client.accepted;
    let previous = initial.document, created, reversed, beforeDelete;
    for (const stage of stages.slice(0, stages.indexOf(options.through) + 1)) {
      const record = { stage, requestId: `${stage}-${randomUUID()}`, status: "running" }; item.turns.push(record);
      try {
        let state;
        if (stage === "undo") {
          const started = performance.now();
          client.state = await bridge.request("advanceIntent");
          client.send({ type: "user.undo", requestId: record.requestId, sceneId: client.state.sceneId, intentEpoch: client.state.intentEpoch });
          state = await bridge.request("undo", {}, record.requestId);
          check(state.undoApplied === true && state.receipt?.status === "installed", "swift_undo_not_installed");
          client.state = state; client.send(state.receipt); client.snapshot();
          record.authoring = "native-host-undo-no-model-call"; record.receipts = [state.receipt]; record.elapsedMS = Math.round(performance.now() - started);
          check(equal(state.document, beforeDelete), "undo_did_not_restore_previous_document");
        } else {
          const flowId = created?.node.nodeId;
          let text, selection;
          if (stage === "create") {
            selection = [fixture.sourceNodeId, fixture.targetNodeId];
            text = `Add exactly one native animated semantic flow annotation to this existing scene; do not generate a 2D image or ordinary arrow primitive. Connect structural node ${fixture.sourceNodeId} at localPoint [0,0,0] to ${fixture.targetNodeId} at localPoint [0,0,0]. Use direction forward, width 0.008 metres, label "${fixture.label}", animated true, and no intermediate route points. Create it as an unparented annotation with parentId null and identity transform. Preserve all existing nodes. Explain that this is a schematic teaching flow, not a physical simulation.`;
          } else if (stage === "reverse") {
            selection = [flowId]; text = `Reverse the existing flow annotation ${flowId} in place. Keep that exact scene node identity and its source, target, local points, route, width, label, animation setting and transform. Change its flow recipe direction from forward to reverse using a geometry update. Do not delete it, create another annotation, or swap its endpoint bindings.`;
          } else if (stage === "transform") {
            selection = [fixture.sourceNodeId]; text = `Translate only structural node ${fixture.sourceNodeId} by [0.05,0.02,0] metres in its parent's coordinates, preserving rotation and scale. Keep flow annotation ${flowId} and its recipe unchanged so its source remains bound to that part. Do not manually move or replace the flow.`;
          } else if (stage === "hide") {
            selection = [flowId]; text = `Hide only flow annotation ${flowId} by setting its existing node visibility to false. Preserve that node identity, recipe, transform, endpoint components and all other scene nodes.`;
          } else {
            selection = [flowId]; text = `Delete only flow annotation node ${flowId}. Keep every structural component and its transform unchanged. The hidden annotation still exists and should be removed by identity; do not merely hide it again.`;
            beforeDelete = structuredClone(previous);
          }
          state = await client.request(record, text, selection);
          check(state.revision > record.sourceRevision, "successful_turn_did_not_advance_revision");
          unchangedSceneContext(previous, state.document, stage === "reverse" ? [created.node.geometryId] : []);
          const found = flows(state.document);
          if (stage === "create") {
            check(found.length === 1 && !initial.document.nodes.some(value => value.nodeId === found[0].node.nodeId), "expected_one_new_semantic_flow");
            check(state.document.nodes.length === initial.document.nodes.length + 1, "unexpected_additional_nodes");
            created = structuredClone(found[0]);
            check(created.node.parentId == null && created.node.isVisible === true && equal(created.node.transform, { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }), "flow_root_visibility_or_transform_mismatch");
            check(created.recipe.source.nodeId === fixture.sourceNodeId && created.recipe.target.nodeId === fixture.targetNodeId, "flow_bindings_mismatch");
            check(equal(created.recipe.source.localPoint, [0, 0, 0]) && equal(created.recipe.target.localPoint, [0, 0, 0]) && equal(created.recipe.routePoints, []), "flow_local_points_or_route_mismatch");
            check(created.recipe.direction === "forward" && created.recipe.animated === true && created.recipe.label === fixture.label && Math.abs(created.recipe.width - 0.008) < 1e-10, "flow_properties_mismatch");
            unchangedStructuralNodes(initial.document, state.document);
          } else if (stage === "delete") {
            check(found.length === 0 && !state.document.nodes.some(value => value.nodeId === created.node.nodeId), "flow_not_deleted");
            check(state.document.nodes.length === previous.nodes.length - 1, "delete_changed_other_node_count");
            unchangedStructuralNodes(previous, state.document, [created.node.nodeId]);
          } else {
            check(found.length === 1 && found[0].node.nodeId === created.node.nodeId, "flow_identity_changed");
            check(state.document.nodes.length === previous.nodes.length, "unexpected_node_count_change");
            if (stage === "reverse") {
              check(equal(found[0].recipe, { ...created.recipe, direction: "reverse" }), "reverse_changed_other_flow_fields");
              check(equal({ ...found[0].node, geometryId: created.node.geometryId }, created.node), "reverse_changed_flow_node_except_geometry");
              unchangedStructuralNodes(initial.document, state.document); reversed = structuredClone(found[0]);
            } else {
              check(equal(found[0].recipe, reversed.recipe), "flow_recipe_changed_during_structural_edit");
              if (stage === "transform") {
                const priorSource = node(previous, fixture.sourceNodeId), changedSource = node(state.document, fixture.sourceNodeId);
                const expected = priorSource.transform.translation.map((value, index) => value + [0.05, 0.02, 0][index]);
                check(changedSource.transform.translation.every((value, index) => Math.abs(value - expected[index]) < 1e-9), "bound_part_translation_mismatch");
                check(equal({ ...changedSource, transform: priorSource.transform }, priorSource) && equal(changedSource.transform.rotation, priorSource.transform.rotation) && equal(changedSource.transform.scale, priorSource.transform.scale), "bound_part_other_fields_changed");
                unchangedStructuralNodes(previous, state.document, [fixture.sourceNodeId]);
                record.bindingPreserved = true; record.renderedPathMovementVerified = false;
              } else {
                check(found[0].node.isVisible === false, "flow_not_hidden");
                check(equal({ ...found[0].node, isVisible: node(previous, created.node.nodeId).isVisible }, node(previous, created.node.nodeId)), "hide_changed_other_flow_node_fields");
                unchangedStructuralNodes(previous, state.document, [created.node.nodeId]);
              }
            }
          }
        }
        record.resultingRevision = state.revision; record.sceneSHA256 = digest(state.document);
        record.acceptedScenePath = await saveScene(options, name, stage, state.document);
        record.flowNodeId = created.node.nodeId; record.status = "passed"; previous = state.document;
      } catch (error) { record.status = "failed"; record.failureCode = error.checkCode ?? "unexpected_failure"; throw error; }
    }
    await client.synchronizeTransport();
    check(!client.failureCode && !bridge.failureCode, client.failureCode ?? bridge.failureCode ?? "transport_failed");
    item.status = "passed";
  } finally { client?.close(); bridge.close(); if (item.status === "running") item.status = "failed"; }
}

if (process.argv.includes("--help")) console.log(help);
else {
  const report = { schema: "astra-flow-live-swift-acceptance/v1", startedAt: new Date().toISOString(), status: "running",
    nativeRenderingVerified: false, physicalARVerified: false, devicePerformanceVerified: false,
    reducer: "Production SpatialCore.SceneState and SceneWireDecoder via persistent SceneLab reducer process.", fixtures: [] };
  const started = performance.now(); let options;
  try {
    options = parseOptions(process.argv.slice(2)); await mkdir(options.out, { recursive: true, mode: 0o700 });
    report.mode = options.prepareOnly ? "offline-fixture-validation" : "live-model-real-Swift-reducer";
    report.reducerBinarySHA256 = checksum(await readFile(options.binary));
    const values = await fixtures();
    const connection = options.prepareOnly ? undefined : await savedConnection(options);
    for (const name of options.fixtures) await exerciseFixture(name, values[name], connection, options, report);
    report.status = options.prepareOnly ? "validated-offline" : "passed";
  } catch (error) { report.status = "failed"; report.failureCode = error.checkCode ?? (error.code === "ENOENT" ? "missing_file_or_scenelab_build" : "unexpected_failure"); process.exitCode = 1; }
  finally {
    report.elapsedMS = Math.round(performance.now() - started);
    if (options) await writeFile(resolve(options.out, "receipt.json"), `${JSON.stringify(report, null, 2)}\n`, { mode: 0o600 });
    console.log(JSON.stringify({ status: report.status, mode: report.mode, failureCode: report.failureCode, elapsedMS: report.elapsedMS,
      receiptPath: options ? resolve(options.out, "receipt.json") : null }));
  }
}
