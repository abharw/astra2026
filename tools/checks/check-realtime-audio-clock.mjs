#!/usr/bin/env node

// Live provider clock check using generated speech, never the device microphone.
// Reuses the running backend's client-secret endpoint; no scene tools are exposed.
import { createRequire } from "node:module";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const require = createRequire(import.meta.url);
const WebSocket = require("../../backend/node_modules/ws");
const root = new URL("../../", import.meta.url);
const startedAt = Date.now();
const deadlineMS = 90_000;
const sampleRate = 24_000;
const sessionID = `audio-clock-${randomUUID()}`;
const output = new URL(`.local/realtime-audio-clock/${startedAt}.json`, root);
const abort = new AbortController();
let socket;
let failure;
let waiters = [];
let sentFrames = 0;
let phase = "connecting";
let configured = false;
let generatedResponseID;
let generatedDone = false;
const generatedChunks = [];
let generatedBytes = 0;
const evidence = {
  schemaVersion: 1,
  evidence: "live-Realtime-provider / generated-speech replay / input-buffer clock",
  nativeMicrophoneVerified: false,
  nativePlaybackVerified: false,
  nativeSceneInstallationVerified: false,
  sceneBackendExecutionVerified: false,
  startedAt: new Date(startedAt).toISOString(),
  deadlineMS,
  sampleRate,
  status: "running",
  events: [],
  replays: [],
};

function check(value, code) {
  if (!value) throw Object.assign(new Error(code), { probeCode: code });
}

function fail(code) {
  if (failure) return;
  failure = Object.assign(new Error(code), { probeCode: code });
  for (const waiter of waiters) waiter.reject(failure);
  waiters = [];
}

function resolveWaiters() {
  const remaining = [];
  for (const waiter of waiters) {
    if (waiter.predicate()) waiter.resolve();
    else remaining.push(waiter);
  }
  waiters = remaining;
}

async function waitFor(predicate) {
  if (failure) throw failure;
  if (predicate()) return;
  await new Promise((resolve, reject) => waiters.push({ predicate, resolve, reject }));
}

async function send(event) {
  if (failure) throw failure;
  check(socket?.readyState === WebSocket.OPEN, "socket_not_open");
  await new Promise((resolve, reject) => socket.send(JSON.stringify(event), error => {
    if (error) reject(Object.assign(new Error(), { probeCode: "socket_send_failed" }));
    else resolve();
  }));
}

function record(event) {
  const entry = {
    type: event.type,
    phase,
    elapsedMS: Date.now() - startedAt,
    sentFramesAtReceipt: sentFrames,
  };
  if (typeof event.item_id === "string") entry.itemID = event.item_id;
  if (Number.isInteger(event.audio_start_ms)) entry.audioStartMS = event.audio_start_ms;
  if (Number.isInteger(event.audio_end_ms)) entry.audioEndMS = event.audio_end_ms;
  if (event.type === "input_audio_buffer.cleared") entry.serverEventID = event.event_id;
  evidence.events.push(entry);
  check(evidence.events.length <= 100, "too_many_events");
}

function receive(raw) {
  try {
    const event = JSON.parse(raw.toString("utf8"));
    switch (event.type) {
      case "session.created":
        evidence.providerSessionID = event.session.id;
        break;
      case "session.updated": {
        const audio = event.session?.audio;
        evidence.configuration = {
          inputFormat: audio?.input?.format,
          outputFormat: audio?.output?.format,
          turnDetection: audio?.input?.turn_detection,
        };
        check(audio?.input?.format?.rate === sampleRate && audio?.output?.format?.rate === sampleRate, "pcm_configuration_mismatch");
        check(audio?.input?.turn_detection?.create_response === false &&
          audio?.input?.turn_detection?.interrupt_response === false, "manual_vad_configuration_mismatch");
        configured = true;
        break;
      }
      case "response.created":
        check(!generatedResponseID, "unexpected_automatic_response");
        generatedResponseID = event.response.id;
        evidence.generatedResponseID = generatedResponseID;
        record(event);
        break;
      case "response.output_audio.delta": {
        check(event.response_id === generatedResponseID, "unexpected_audio_response");
        const bytes = Buffer.from(event.delta, "base64");
        check(bytes.length % 2 === 0, "odd_pcm16_bytes");
        generatedBytes += bytes.length;
        check(generatedBytes <= sampleRate * 2 * 12, "generated_audio_exceeds_12_seconds");
        generatedChunks.push(bytes);
        break;
      }
      case "response.done":
        check(event.response.id === generatedResponseID && event.response.status === "completed", "audio_generation_failed");
        check(generatedBytes > 0, "missing_generated_audio");
        evidence.generatedPCMBytes = generatedBytes;
        evidence.generatedPCMFrames = generatedBytes / 2;
        evidence.generatedDurationMS = generatedBytes / 48;
        generatedDone = true;
        record(event);
        break;
      case "input_audio_buffer.speech_started":
      case "input_audio_buffer.speech_stopped":
      case "input_audio_buffer.committed":
      case "input_audio_buffer.cleared":
        record(event);
        break;
      case "error":
        evidence.providerErrorCode = /^[a-z0-9_]{1,100}$/.test(event.error?.code ?? "") ? event.error.code : "unclassified";
        fail("provider_error");
        break;
    }
    resolveWaiters();
  } catch (error) {
    fail(error.probeCode ?? "invalid_provider_event");
  }
}

async function replay(pcm, name) {
  phase = name;
  const entry = { phase: name, startFrame: sentFrames, startMS: sentFrames / 24 };
  evidence.replays.push(entry);
  // Padding is real zero-valued PCM in this synthetic replay, not wall-clock delay.
  const input = Buffer.concat([Buffer.alloc(600 * 48), pcm, Buffer.alloc(1_000 * 48)]);
  entry.pcmFrames = input.length / 2;
  for (let offset = 0; offset < input.length; offset += 960) {
    const chunk = input.subarray(offset, Math.min(offset + 960, input.length));
    await send({ type: "input_audio_buffer.append", audio: chunk.toString("base64") });
    sentFrames += chunk.length / 2;
    await new Promise(resolve => setTimeout(resolve, chunk.length / 48));
    if (failure) throw failure;
  }
  entry.endFrame = sentFrames;
  entry.endMS = sentFrames / 24;
  await waitFor(() => evidence.events.some(event => event.phase === name && event.type === "input_audio_buffer.committed"));
  const starts = evidence.events.filter(event => event.phase === name && event.type === "input_audio_buffer.speech_started");
  const stops = evidence.events.filter(event => event.phase === name && event.type === "input_audio_buffer.speech_stopped");
  const commits = evidence.events.filter(event => event.phase === name && event.type === "input_audio_buffer.committed");
  check(starts.length === 1 && stops.length === 1 && commits.length === 1, "expected_one_utterance_per_replay");
  check(starts[0].itemID === stops[0].itemID && starts[0].itemID === commits[0].itemID, "utterance_item_id_mismatch");
  entry.itemID = starts[0].itemID;
  entry.audioStartMS = starts[0].audioStartMS;
  entry.audioEndMS = stops[0].audioEndMS;
}

const timer = setTimeout(() => {
  fail("probe_deadline_exceeded");
  abort.abort();
  socket?.terminate();
}, deadlineMS);

try {
  let savedConfig = {};
  try { savedConfig = JSON.parse(await readFile(new URL(".local/dev-session.json", root), "utf8")); }
  catch (error) { if (error.code !== "ENOENT") check(false, "invalid_local_development_config"); }
  const baseURL = process.env.ASTRA_SESSION_BASE_URL ?? savedConfig.url ?? "http://127.0.0.1:8787";
  const token = process.env.ASTRA_SESSION_TOKEN ?? process.env.SESSION_ACCESS_TOKEN ?? savedConfig.token;
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const credentialResponse = await fetch(new URL("/realtime/client-secret", baseURL), {
    method: "POST", headers, body: JSON.stringify({ sessionId: sessionID }),
    signal: AbortSignal.any([abort.signal, AbortSignal.timeout(15_000)]),
  });
  evidence.credentialHTTPStatus = credentialResponse.status;
  check(credentialResponse.ok, "credential_http_failed");
  const credential = await credentialResponse.json();
  check(typeof credential.clientSecret?.value === "string" && credential.model === "gpt-realtime-2.1", "credential_schema_mismatch");
  evidence.model = credential.model;
  socket = new WebSocket(`wss://api.openai.com/v1/realtime?model=${encodeURIComponent(credential.model)}`, {
    headers: { Authorization: `Bearer ${credential.clientSecret.value}` },
    handshakeTimeout: 15_000,
    maxPayload: 2 * 1024 * 1024,
  });
  socket.on("message", receive);
  socket.on("error", () => fail("websocket_transport_failed"));
  socket.on("close", () => fail("websocket_closed"));
  await new Promise((resolve, reject) => {
    socket.once("open", resolve);
    socket.once("error", () => reject(Object.assign(new Error(), { probeCode: "websocket_connect_failed" })));
  });
  await send({
    type: "session.update",
    session: {
      type: "realtime", output_modalities: ["audio"], tools: [], tool_choice: "none",
      audio: {
        input: {
          format: { type: "audio/pcm", rate: sampleRate },
          noise_reduction: { type: "near_field" },
          transcription: null,
          turn_detection: {
            type: "server_vad", threshold: 0.5, prefix_padding_ms: 300,
            silence_duration_ms: 450, create_response: false, interrupt_response: false,
          },
        },
        output: { format: { type: "audio/pcm", rate: sampleRate }, voice: "marin" },
      },
    },
  });
  await waitFor(() => configured);
  phase = "generate_synthetic_speech";
  await send({
    type: "response.create",
    response: {
      conversation: "none", output_modalities: ["audio"], tool_choice: "none", max_output_tokens: 256,
      instructions: "Say exactly once, in one continuous sentence: This spoken sentence checks the clock.",
      input: [{ type: "message", role: "user", content: [{ type: "input_text", text: "Generate the fixed synthetic test sentence only." }] }],
      metadata: { purpose: "synthetic_audio_clock_probe" },
    },
  });
  await waitFor(() => generatedDone);
  const pcm = Buffer.concat(generatedChunks);
  await replay(pcm, "before_clear");
  phase = "clear_pending";
  evidence.clear = { boundaryFrames: sentFrames, boundaryMS: sentFrames / 24, sentAtMS: Date.now() - startedAt };
  await send({ type: "input_audio_buffer.clear", event_id: `clock_clear_${randomUUID()}` });
  await waitFor(() => evidence.events.some(event => event.type === "input_audio_buffer.cleared"));
  evidence.clear.acknowledgedAtMS = Date.now() - startedAt;
  await replay(pcm, "after_clear");
  const [before, after] = evidence.replays;
  evidence.analysis = {
    explicitClearAcknowledged: true,
    postClearStartAtOrBeyondSentFloor: after.audioStartMS >= evidence.clear.boundaryMS,
    postClearEndAtOrBeyondSentFloor: after.audioEndMS >= evidence.clear.boundaryMS,
    relativeStartBeforeMS: before.audioStartMS - before.startMS,
    relativeStartAfterMS: after.audioStartMS - after.startMS,
    relativeStartDifferenceMS: (after.audioStartMS - after.startMS) - (before.audioStartMS - before.startMS),
    noAutomaticResponse: evidence.events.filter(event => event.type === "response.created").length === 1,
    scope: "One generated-PCM replay per side of explicit clear; no native capture, playback, or arbitrary asynchronous-event barrier proof.",
  };
  check(evidence.analysis.postClearStartAtOrBeyondSentFloor && evidence.analysis.postClearEndAtOrBeyondSentFloor, "post_clear_clock_not_session_cumulative");
  evidence.status = "passed";
} catch (error) {
  evidence.status = "failed";
  evidence.failureCode = error.probeCode ?? failure?.probeCode ?? "unexpected_failure";
  process.exitCode = 1;
} finally {
  clearTimeout(timer);
  socket?.terminate();
  evidence.elapsedMS = Date.now() - startedAt;
  evidence.totalSentFrames = sentFrames;
  await mkdir(new URL(".local/realtime-audio-clock/", root), { recursive: true });
  await writeFile(output, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(JSON.stringify({ status: evidence.status, failureCode: evidence.failureCode, elapsedMS: evidence.elapsedMS, analysis: evidence.analysis, evidencePath: fileURLToPath(output) }, null, 2));
}
