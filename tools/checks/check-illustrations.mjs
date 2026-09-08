#!/usr/bin/env node

// Product-wire acceptance using fixture phone snapshots, not a native device.
// Default: the running backend, real authoring model, real image provider.
// Optional injected authoring uses the same SessionServer and HTTP/WS routes.
import { createHash, randomUUID } from "node:crypto";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { fileURLToPath, pathToFileURL } from "node:url";
import { isAbsolute, relative, resolve } from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const localRoot = resolve(root, ".local");
const require = createRequire(import.meta.url);
const allScenarios = ["rack", "refine", "lamp", "cache", "cancel", "stale"];
const help = `Usage: node tools/checks/check-illustrations.mjs [options]

--mode live|injected-authoring   Default live: use the configured running backend.
--url URL                       Override ASTRA_SESSION_BASE_URL / .local/dev-session.json.
--scenarios LIST                Comma-separated: ${allScenarios.join(",")} (default all).
--out DIRECTORY                 Receipt and verified PNGs, always beneath .local/.
--timeout-ms NUMBER             Model/image state deadline, 10000..240000 (default 210000).
--observe-ms NUMBER             Late-event observation, 250..30000 (default 2000).
--help                          Print help without reading credentials or contacting a server.

Live mode uses ASTRA_SESSION_TOKEN / SESSION_ACCESS_TOKEN / saved token silently.
Injected authoring requires OPENAI_API_KEY and a fresh backend build. It starts a
loopback SessionServer with exact propose_scene results and the real image API.
Its cache evidence counts actual provider dispatches. For cancel/stale only,
injected mode delays provider dispatch 1000 ms to avoid needless paid generations;
this is a bounded wire-fence check, not a delayed-provider-completion test.

All modes use synthetic fixture snapshots. Neither proves native rendering,
physical scene observation, microphone behavior, or image correctness.
A live cache miss is reported as unverified, never claimed as cache reuse.
Refine/cache automatically include the prerequisite rack generation.
PNG download and authorization probes have separate bounded HTTP deadlines.
Examples:
  node tools/checks/check-illustrations.mjs --scenarios rack,refine,lamp
  node tools/checks/check-illustrations.mjs --mode injected-authoring --scenarios rack,cache,cancel,stale
`;

function check(condition, code) {
  if (!condition) throw Object.assign(new Error(code), { acceptanceCode: code });
}
function sha256(value) { return createHash("sha256").update(value).digest("hex"); }
function boundedInteger(value, minimum, maximum, code) {
  const number = Number(value);
  check(Number.isSafeInteger(number) && number >= minimum && number <= maximum, code);
  return number;
}
function parseOptions(args) {
  const options = { mode: "live", scenarios: [...allScenarios], timeoutMS: 210_000, observeMS: 2_000 };
  const names = new Set(["--mode", "--url", "--scenarios", "--out", "--timeout-ms", "--observe-ms"]);
  for (let index = 0; index < args.length; index += 2) {
    const name = args[index], value = args[index + 1];
    check(names.has(name) && typeof value === "string" && !value.startsWith("--"), "invalid_arguments_use_help");
    if (name === "--mode") options.mode = value;
    if (name === "--url") options.url = value;
    if (name === "--out") options.out = value;
    if (name === "--scenarios") options.scenarios = [...new Set(value.split(","))];
    if (name === "--timeout-ms") options.timeoutMS = boundedInteger(value, 10_000, 240_000, "invalid_timeout");
    if (name === "--observe-ms") options.observeMS = boundedInteger(value, 250, 30_000, "invalid_observation_window");
  }
  check(["live", "injected-authoring"].includes(options.mode), "invalid_mode");
  check(options.scenarios.length > 0 && options.scenarios.every(name => allScenarios.includes(name)), "invalid_scenarios");
  if (options.scenarios.some(name => ["refine", "cache"].includes(name)) && !options.scenarios.includes("rack")) options.scenarios.unshift("rack");
  options.out = resolve(root, options.out ?? `.local/illustration-acceptance/${new Date().toISOString().replaceAll(":", "-")}-${options.mode}`);
  const localPath = relative(localRoot, options.out);
  check(localPath !== "" && !localPath.startsWith("..") && !isAbsolute(localPath), "output_must_be_beneath_local");
  return options;
}
function safeCode(value) { return typeof value === "string" && /^[a-zA-Z0-9_.:-]{1,100}$/.test(value) ? value : "unclassified"; }

class WireClient {
  constructor(url, token, fixture, options, onEvent) {
    this.options = options;
    this.fixture = fixture;
    this.sceneId = `illustration-acceptance-${randomUUID()}`;
    this.revision = 7;
    this.intentEpoch = 1;
    this.events = [];
    this.waiters = new Set();
    this.onEvent = onEvent;
    const socketURL = new URL("/session", url);
    socketURL.protocol = socketURL.protocol === "https:" ? "wss:" : "ws:";
    const WebSocket = require("../../backend/node_modules/ws");
    this.socket = new WebSocket(socketURL, { handshakeTimeout: 15_000, maxPayload: 256 * 1024 });
    this.socket.on("message", raw => {
      try {
        const message = JSON.parse(raw.toString("utf8"));
        check(typeof message.type === "string", "invalid_server_envelope");
        check(message.type !== "session.error", `session_error:${safeCode(message.code)}`);
        check(!["scene.patch", "generation.begin", "generation.batch", "generation.finish"].includes(message.type), "unexpected_scene_mutation_proposal");
        const event = { message, at: performance.now(), index: this.events.length };
        this.events.push(event);
        if (this.events.length > 2_000) throw Object.assign(new Error(), { acceptanceCode: "too_many_server_events" });
        this.onEvent(event);
        for (const waiter of [...this.waiters]) waiter();
      } catch (error) { this.fail(error.acceptanceCode ?? "invalid_server_json"); }
    });
    this.socket.on("error", () => this.fail("websocket_transport_failed"));
    this.socket.on("close", () => { if (!this.closing) this.fail("websocket_closed_early"); });
    this.opened = new Promise((done, reject) => {
      this.socket.once("open", () => {
        this.send({ type: "session.hello", protocolVersion: 1, sessionId: `check-${randomUUID()}`,
          sceneId: this.sceneId, revision: this.revision, intentEpoch: this.intentEpoch,
          sceneSchemaVersions: [1], geometrySemanticsVersions: [1], capabilities: ["box.v1", "illustration.v1"],
          ...(token ? { authToken: token } : {}) });
        done();
      });
      this.socket.once("error", () => reject(Object.assign(new Error(), { acceptanceCode: "websocket_open_failed" })));
    });
  }
  fail(code) { this.failureCode ??= code; for (const waiter of [...this.waiters]) waiter(); }
  send(message) {
    check(this.socket.readyState === 1, "websocket_not_open");
    this.socket.send(JSON.stringify(message));
  }
  snapshot({ advanceIntent = false, advanceRevision = false } = {}) {
    if (advanceIntent) this.intentEpoch += 1;
    if (advanceRevision) {
      this.revision += 1;
      // A real document change accompanies the synthetic phone revision change.
      this.fixture.document = structuredClone(this.fixture.document);
      const transform = this.fixture.document.nodes[0].transform;
      transform.translation[0] += 0.01;
    }
    this.send({ type: "phone.snapshot", sceneId: this.sceneId, revision: this.revision,
      intentEpoch: this.intentEpoch, document: this.fixture.document });
  }
  async accept() {
    await this.opened;
    const accepted = await this.wait(event => event.message.type === "session.accepted", 0, 15_000);
    check(accepted.message.illustrationEnabled === true, "backend_did_not_enable_illustrations");
    this.snapshot();
  }
  wait(predicate, from = 0, timeoutMS = this.options.timeoutMS) {
    return new Promise((done, reject) => {
      const finish = (error, value) => {
        clearTimeout(timer); this.waiters.delete(scan); error ? reject(error) : done(value);
      };
      const scan = () => {
        if (this.failureCode) return finish(Object.assign(new Error(), { acceptanceCode: this.failureCode }));
        for (const event of this.events.slice(from)) {
          if (event.message.type === "session.error") return finish(Object.assign(new Error(), { acceptanceCode: `session_error:${safeCode(event.message.code)}` }));
          if (["scene.patch", "generation.begin", "generation.batch", "generation.finish"].includes(event.message.type)) return finish(Object.assign(new Error(), { acceptanceCode: "unexpected_scene_mutation_proposal" }));
          if (predicate(event)) return finish(undefined, event);
        }
      };
      const timer = setTimeout(() => finish(Object.assign(new Error(), { acceptanceCode: "event_timeout" })), timeoutMS);
      this.waiters.add(scan); scan();
    });
  }
  async observeJob(jobId, from) {
    // A bounded observation window, not proof against every possible late response.
    await new Promise(resolveWait => setTimeout(resolveWait, this.options.observeMS));
    check(!this.failureCode, this.failureCode ?? "websocket_failed");
    check(!this.events.slice(from).some(event => event.message.type === "illustration.state" && event.message.jobId === jobId && event.message.status === "ready"), "ready_after_terminal_fence");
  }
  close() { this.closing = true; this.socket.terminate(); }
}

async function loadFixtures() {
  const path = "framework/contract/fixtures/accepted/imported_rack_document.json";
  const bytes = await readFile(resolve(root, path));
  const rack = { path, sha256: sha256(bytes), document: JSON.parse(bytes), nodeIds: ["rack01.server01"] };
  check(rack.document.nodes.some(node => node.nodeId === rack.nodeIds[0]), "rack_selection_missing");
  const lampDocument = {
    schemaVersion: 1, geometrySemanticsVersion: 1, documentId: "synthetic-lamp-illustration-acceptance",
    geometryDefinitions: [], materials: [], relationships: [
      { relationshipId: "lamp.energy", kind: "electricalSupply", sourceNodeId: "lamp.base", targetNodeId: "lamp.bulb", description: "Illustrative energy path; no electrical simulation or measured internals." }
    ],
    nodes: [
      { nodeId: "lamp", semantic: { name: "Teaching desk lamp", role: "assembly", description: "Synthetic non-rack teaching fixture, not an observed physical lamp." } },
      { nodeId: "lamp.base", parentId: "lamp", semantic: { name: "Lamp base and switch", role: "power supply", description: "Illustrative switch and base; no specific circuit is known." } },
      { nodeId: "lamp.bulb", parentId: "lamp", semantic: { name: "Lamp bulb", role: "light source", description: "Illustrative conversion of electrical energy into light and heat." } }
    ].map(node => ({ ...node, transform: { translation: [0, 0, 0], rotation: [0, 0, 0, 1], scale: [1, 1, 1] }, isVisible: true,
      provenance: { origin: "generated", factualSupport: "illustrative", sourceRefs: [] } }))
  };
  return { rack, lamp: { path: "inline:synthetic-teaching-lamp", sha256: sha256(JSON.stringify(lampDocument)), document: lampDocument, nodeIds: ["lamp.bulb"] } };
}

async function validateArtifact(artifact, state, connection, options) {
  check(artifact && /^[a-f0-9]{64}$/.test(artifact.sha256 ?? ""), "invalid_artifact_checksum");
  const hash = artifact.sha256;
  check(artifact.artifactId === `sha256:${hash}` && artifact.path === `/illustrations/artifacts/${hash}.png`, "invalid_artifact_route_or_id");
  check(artifact.mimeType === "image/png" && artifact.model === "gpt-image-2.5-flare", "artifact_type_or_model_mismatch");
  check(artifact.sourceRevision === state.revision, "artifact_source_revision_mismatch");
  check(artifact.width === 1024 && artifact.height === 1024, "artifact_dimensions_mismatch");
  check(Number.isSafeInteger(artifact.byteCount) && artifact.byteCount > 32 && artifact.byteCount <= 8 * 1024 * 1024, "artifact_size_invalid");
  const started = performance.now();
  const response = await fetch(new URL(artifact.path, connection.url), {
    headers: connection.token ? { Authorization: `Bearer ${connection.token}` } : {},
    redirect: "error", signal: AbortSignal.timeout(30_000)
  });
  check(response.ok, "artifact_http_failed");
  check(response.headers.get("content-type")?.split(";")[0] === "image/png", "artifact_http_type_mismatch");
  const chunks = []; let length = 0;
  for await (const chunk of response.body) {
    length += chunk.byteLength;
    check(length <= 8 * 1024 * 1024, "artifact_http_body_too_large"); chunks.push(chunk);
  }
  const bytes = Buffer.concat(chunks);
  check(bytes.length === artifact.byteCount && sha256(bytes) === hash, "artifact_bytes_or_checksum_mismatch");
  check(bytes.subarray(0, 8).equals(Buffer.from([137, 80, 78, 71, 13, 10, 26, 10])) && bytes.readUInt32BE(8) === 13 && bytes.toString("ascii", 12, 16) === "IHDR", "invalid_png_header");
  check(bytes.readUInt32BE(16) === artifact.width && bytes.readUInt32BE(20) === artifact.height, "png_dimensions_mismatch");
  const savedPath = resolve(options.out, `${hash}.png`);
  await writeFile(savedPath, bytes, { flag: "w", mode: 0o600 });
  if (connection.token && !connection.artifactAuthorizationVerified) {
    for (const headers of [{}, { Authorization: "Bearer deliberately-invalid-acceptance-token" }]) {
      const denied = await fetch(new URL(artifact.path, connection.url), {
        headers, redirect: "error", signal: AbortSignal.timeout(10_000)
      });
      await denied.body?.cancel();
      check(denied.status === 401 || denied.status === 403, "artifact_authorization_not_enforced");
    }
    connection.artifactAuthorizationVerified = true;
  }
  return { artifactId: artifact.artifactId, sha256: hash, model: artifact.model, mimeType: artifact.mimeType,
    width: artifact.width, height: artifact.height, byteCount: bytes.length, sourceRevision: artifact.sourceRevision,
    sourceArtifactId: artifact.sourceArtifactId ?? null, authenticatedGET: Boolean(connection.token),
    missingAndInvalidTokenRejected: connection.artifactAuthorizationVerified === true, httpStatus: response.status,
    downloadMS: Math.round(performance.now() - started), savedPath: relative(root, savedPath) };
}

async function connectionFor(options, plans, evidence) {
  let config = {};
  try { config = JSON.parse(await readFile(resolve(localRoot, "dev-session.json"), "utf8")); }
  catch (error) { check(error.code === "ENOENT", "invalid_local_development_config"); }
  if (options.mode === "live") {
    const url = new URL(options.url ?? process.env.ASTRA_SESSION_BASE_URL ?? config.url ?? "http://127.0.0.1:8787");
    if (url.protocol === "ws:") url.protocol = "http:";
    if (url.protocol === "wss:") url.protocol = "https:";
    check(["http:", "https:"].includes(url.protocol) && !url.username && !url.password, "invalid_backend_url");
    return { url, token: process.env.ASTRA_SESSION_TOKEN ?? process.env.SESSION_ACCESS_TOKEN ?? config.token,
      providerDispatchCount: () => null, close: async () => {} };
  }
  check(!options.url, "injected_mode_cannot_use_url");
  check(typeof process.env.OPENAI_API_KEY === "string" && process.env.OPENAI_API_KEY.length > 0, "openai_api_key_missing");
  const { SessionServer } = await import(pathToFileURL(resolve(root, "backend/dist/server.js")));
  const calls = [];
  const model = { async *stream(request) {
    const plan = plans.get(request.requestId);
    check(plan, "scripted_authoring_plan_missing");
    plan.authoringCalls = (plan.authoringCalls ?? 0) + 1;
    yield { type: "function_call", name: "propose_scene", arguments: JSON.stringify({ mode: "explanation",
      explanation: "The illustration is being prepared from the selected teaching fixture.", scopeParentNodeId: null,
      operations: [], illustration: { brief: plan.brief, componentNodeIds: plan.nodeIds, sourceArtifactId: plan.sourceArtifactId ?? null } }) };
    yield { type: "done" };
  } };
  let dispatchDelayMS = 0;
  const fetchImpl = async (input, init) => {
    const url = new URL(typeof input === "string" || input instanceof URL ? input : input.url);
    const isImage = /^\/v1\/images\/(generations|edits)$/.test(url.pathname);
    if (isImage && dispatchDelayMS > 0) {
      await new Promise((done, reject) => {
        const signal = init?.signal;
        const abort = () => { clearTimeout(timer); reject(new DOMException("Aborted", "AbortError")); };
        const timer = setTimeout(() => { signal?.removeEventListener("abort", abort); done(); }, dispatchDelayMS);
        if (signal?.aborted) abort(); else signal?.addEventListener("abort", abort, { once: true });
      });
    }
    if (isImage) {
      const call = { kind: url.pathname.endsWith("/edits") ? "edit" : "generation", dispatchedAt: new Date().toISOString() };
      if (call.kind === "edit") {
        const image = init?.body instanceof FormData ? init.body.get("image[]") : null;
        check(image && typeof image.arrayBuffer === "function", "refinement_multipart_image_missing");
        call.inputImageSHA256 = sha256(Buffer.from(await image.arrayBuffer()));
      }
      calls.push(call);
    }
    const call = isImage ? calls.at(-1) : undefined;
    try { const response = await fetch(input, init); if (call) call.httpStatus = response.status; return response; }
    catch (error) { if (call) call.transportOutcome = error.name === "AbortError" ? "aborted" : "failed"; throw error; }
  };
  const token = randomUUID();
  const server = new SessionServer({ host: "127.0.0.1", port: 0, apiKey: process.env.OPENAI_API_KEY, accessToken: token,
    model, fetchImpl, illustrationDirectory: resolve(options.out, "server-artifacts"), logger: { log() {} } });
  await server.listen();
  evidence.providerDispatches = calls;
  return { url: new URL(server.address()), token, providerDispatchCount: () => calls.length,
    providerCalls: calls, setDispatchDelay: value => { dispatchDelayMS = value; }, close: () => server.close() };
}

async function run(options, evidence) {
  const fixtures = await loadFixtures(), plans = new Map(), clients = new Map();
  const connection = await connectionFor(options, plans, evidence);
  let active;
  const onEvent = event => {
    if (!active || event.message.requestId !== active.requestId) return;
    const message = event.message;
    if (message.type === "illustration.state") {
      active.states.push({ status: message.status, atMS: Math.round(event.at - active.started), jobId: message.jobId,
        sceneId: message.sceneId, revision: message.revision, intentEpoch: message.intentEpoch,
        componentNodeIds: message.componentNodeIds, cacheHit: message.cacheHit ?? null });
      if (message.status === "generating" && !active.controlSent) {
        if (active.name === "rack") {
          active.controlSent = true;
          active.client.snapshot({ advanceIntent: true });
        }
        if (active.name === "cancel") { active.controlSent = true; active.client.send({ type: "illustration.cancel", jobId: message.jobId }); }
        if (active.name === "stale") { active.controlSent = true; active.client.snapshot({ advanceRevision: true }); }
      }
    }
  };
  const getClient = async name => {
    if (clients.has(name)) return clients.get(name);
    const client = new WireClient(connection.url, connection.token, structuredClone(fixtures[name]), options, onEvent);
    clients.set(name, client); await client.accept(); return client;
  };
  const rackBrief = "Create a clean educational 2D cutaway diagram of the selected server showing an illustrative heat-flow path from heat-generating electronics, through cooling air, to exhaust. Label hot and cool air. Distinguish schematic internals from source-backed exterior; do not claim measured temperatures or exact internal hardware.";
  let rackArtifact, rackJobId;
  try {
    for (const name of allScenarios.filter(name => options.scenarios.includes(name))) {
      const fixtureName = name === "lamp" ? "lamp" : "rack";
      const client = await getClient(fixtureName);
      const nodeIds = client.fixture.nodeIds;
      let brief = name === "lamp" ? "Create a clean educational 2D illustration of the selected desk-lamp bulb showing electrical energy becoming visible light and heat. Label the energy paths. Treat the component as a generic synthetic teaching example; do not invent an exact lamp circuit." : rackBrief;
      if (name === "refine") brief = "Refine the previous approved server heat-flow illustration: retain its composition and labels, and emphasize the exhaust arrow in orange. Keep the illustrative qualification and do not introduce extra hardware.";
      if (name === "cancel") brief = `${rackBrief} Put a small C in the lower-right corner for this cancellation acceptance request.`;
      if (name === "stale") brief = `${rackBrief} Put a small S in the lower-right corner for this scene-change acceptance request.`;
      const sourceArtifactId = name === "refine" ? rackArtifact?.artifactId : null;
      if (name === "refine") check(sourceArtifactId, "refinement_source_unavailable");
      client.snapshot({ advanceIntent: true });
      const requestId = `${name}-${randomUUID()}`;
      const plan = { brief, nodeIds, sourceArtifactId };
      plans.set(requestId, plan);
      connection.setDispatchDelay?.(["cancel", "stale"].includes(name) ? 1_000 : 0);
      const beforeCalls = connection.providerDispatchCount();
      const started = performance.now(), from = client.events.length;
      const remainingMS = () => Math.max(1, Math.ceil(options.timeoutMS - (performance.now() - started)));
      active = { name, requestId, client, started, states: [] };
      const record = { name, status: "running", requestId, fixture: client.fixture.path, fixtureSHA256: client.fixture.sha256,
        selectedNodeIds: nodeIds, sceneId: client.sceneId, sceneRevision: client.revision, intentEpoch: client.intentEpoch,
        authoring: options.mode === "live" ? "live-model-propose_scene" : "injected-propose_scene",
        sourceArtifactId, states: active.states, providerDispatchDelayMS: options.mode === "injected-authoring" && ["cancel", "stale"].includes(name) ? 1_000 : 0 };
      evidence.scenarios.push(record);
      const text = `Generate a 2D illustration for the selected component in the explanation panel. Do not change the 3D scene. Use this exact illustration brief: ${brief}${sourceArtifactId ? ` Refine the existing image using sourceArtifactId ${sourceArtifactId}; do not start from an unrelated image.` : " Set sourceArtifactId to null for this standalone image."} Use only these selected component IDs: ${nodeIds.join(", ")}.`;
      client.send({ type: "user.request", requestId, text, selection: { nodeIds } });
      try {
        const first = await client.wait(event => event.message.type === "illustration.state" && event.message.requestId === requestId, from, remainingMS());
        record.firstStateLatencyMS = Math.round(first.at - started);
        check(first.message.status === "generating", "first_illustration_state_not_generating");
        const jobId = first.message.jobId;
        record.jobId = jobId;
        check(typeof jobId === "string" && jobId.length > 0, "illustration_job_id_missing");
        check(first.message.sceneId === record.sceneId && first.message.revision === record.sceneRevision && first.message.intentEpoch === record.intentEpoch, "illustration_admission_mismatch");
        check(Array.isArray(first.message.componentNodeIds) && first.message.componentNodeIds.length > 0 && first.message.componentNodeIds.every(id => nodeIds.includes(id)), "illustration_component_selection_mismatch");
        const terminal = await client.wait(event => event.message.type === "illustration.state" && event.message.jobId === jobId && ["ready", "failed", "cancelled", "stale"].includes(event.message.status), first.index, remainingMS());
        record.finalStateLatencyMS = Math.round(terminal.at - started);
        record.terminalStatus = terminal.message.status;
        check(terminal.message.requestId === requestId && Array.isArray(terminal.message.componentNodeIds) && JSON.stringify([...terminal.message.componentNodeIds].sort()) === JSON.stringify([...first.message.componentNodeIds].sort()), "terminal_request_or_components_mismatch");
        check(terminal.message.sceneId === record.sceneId && terminal.message.revision === record.sceneRevision && terminal.message.intentEpoch === record.intentEpoch, "terminal_admission_mismatch");
        const expected = name === "cancel" ? "cancelled" : name === "stale" ? "stale" : "ready";
        check(terminal.message.status === expected, `illustration_terminal_${safeCode(terminal.message.status)}_expected_${expected}`);
        if (["cancel", "stale"].includes(name)) {
          check(active.controlSent, "control_was_not_sent");
          await client.observeJob(jobId, terminal.index + 1);
          record.lateReadyObservationMS = options.observeMS;
          record.lateReadyObserved = false;
          record.longDelayCompletionFenceVerified = false;
        } else {
          const explanation = await client.wait(event => event.message.type === "session.explanation" && event.message.requestId === requestId, from, Math.min(10_000, remainingMS()));
          record.explanationLatencyMS = Math.round(explanation.at - started);
          record.explanationIndependentOfImage = explanation.at < terminal.at;
          // Cache can complete immediately; independent scheduling has no guaranteed wire ordering there.
          if (terminal.message.cacheHit !== true) check(record.explanationIndependentOfImage, "explanation_waited_for_image_completion");
          record.artifact = await validateArtifact(terminal.message.artifact, terminal.message, connection, options);
          if (name === "rack") {
            rackArtifact = record.artifact;
            rackJobId = jobId;
            record.higherIntentEpochSnapshotSentBeforeReady = active.controlSent && client.intentEpoch > record.intentEpoch;
            record.epochSnapshotAcceptanceObserved = false;
          }
          if (name === "refine") {
            check(record.artifact.sourceArtifactId === sourceArtifactId, "refinement_source_artifact_mismatch");
            if (connection.providerCalls) {
              const editCalls = connection.providerCalls.slice(beforeCalls);
              check(editCalls.length === 1 && editCalls[0].kind === "edit" && editCalls[0].inputImageSHA256 === rackArtifact.sha256, "refinement_did_not_edit_source_png");
              record.sourcePNGUploadedToEditEndpointVerified = true;
            }
          }
          record.cacheHit = terminal.message.cacheHit === true;
          if (name === "cache") {
            check(jobId !== rackJobId, "cache_reused_previous_job_identity");
            record.sameArtifactAsRack = record.artifact.artifactId === rackArtifact.artifactId;
            record.cacheReuseVerified = record.cacheHit && record.sameArtifactAsRack;
            if (options.mode === "injected-authoring") {
              check(record.cacheReuseVerified, "deterministic_cache_reuse_failed");
              check(connection.providerDispatchCount() === beforeCalls, "cache_hit_dispatched_provider_request");
              record.zeroProviderDispatchesVerified = true;
            } else {
              record.zeroProviderDispatchesVerified = false;
              record.cacheLimitation = record.cacheReuseVerified ? "Server cacheHit flag verified; provider dispatch count is unavailable in live mode." : "Live authoring can change the brief; cache reuse was not established.";
            }
          }
        }
        check(!client.failureCode, client.failureCode ?? "websocket_failed");
        record.status = name === "cache" && !record.cacheReuseVerified ? "unverified" : "passed";
      } finally {
        record.elapsedMS = Math.round(performance.now() - started);
        record.providerDispatchCount = beforeCalls === null ? null : connection.providerDispatchCount() - beforeCalls;
        if (options.mode === "injected-authoring") record.authoringCalls = plan.authoringCalls ?? 0;
        if (record.status === "running") record.status = "failed";
        active = undefined;
      }
    }
    for (const client of clients.values()) check(!client.failureCode, client.failureCode ?? "websocket_failed");
  } finally {
    for (const client of clients.values()) client.close();
    await connection.close();
  }
}

if (process.argv.includes("--help")) {
  console.log(help);
} else {
  let options;
  const started = performance.now();
  const evidence = { schema: "astra-illustration-wire-acceptance/v1", startedAt: new Date().toISOString(), status: "running",
    nativeUIVerified: false, physicalSceneObserved: false, visualContentCorrectnessVerified: false,
    inputBoundary: "Synthetic phone snapshots from a repository rack fixture and an inline illustrative lamp fixture.", scenarios: [] };
  try {
    options = parseOptions(process.argv.slice(2));
    evidence.mode = options.mode;
    evidence.authoringBoundary = options.mode === "live" ? "Real model chooses propose_scene over the running product wire." : "Exact injected propose_scene; does not establish real model selection. Image generation/edit calls use the real provider.";
    await mkdir(options.out, { recursive: true, mode: 0o700 });
    await run(options, evidence);
    evidence.status = evidence.scenarios.some(record => record.status === "unverified") ? "partial" : "passed";
  } catch (error) {
    evidence.status = "failed";
    evidence.failureCode = error.acceptanceCode ?? "unexpected_failure";
    process.exitCode = 1;
  } finally {
    evidence.elapsedMS = Math.round(performance.now() - started);
    if (options) await writeFile(resolve(options.out, "receipt.json"), `${JSON.stringify(evidence, null, 2)}\n`, { mode: 0o600 });
    console.log(JSON.stringify({ status: evidence.status, mode: evidence.mode, failureCode: evidence.failureCode,
      elapsedMS: evidence.elapsedMS, receiptPath: options ? resolve(options.out, "receipt.json") : null }));
  }
}
