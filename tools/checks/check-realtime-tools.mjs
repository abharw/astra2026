#!/usr/bin/env node

// Live provider contract check. The scene result is deliberately synthetic.
// Uses the running backend's /realtime/client-secret endpoint; never restarts it.
// Run: node tools/checks/check-realtime-tools.mjs
// Optional: ASTRA_SESSION_BASE_URL, ASTRA_SESSION_TOKEN, REALTIME_SMOKE_TIMEOUT_MS.

import { createRequire } from "node:module";
import { mkdir, readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const require = createRequire(import.meta.url);
const WebSocket = require("../../backend/node_modules/ws");
const root = new URL("../../", import.meta.url);
const output = new URL("docs/evidence/realtime-tools-smoke.json", root);
const startedAt = Date.now();
const model = "gpt-realtime-2.1";
const sessionID = `realtime-tools-${randomUUID()}`;
const configuredTimeout = Number(process.env.REALTIME_SMOKE_TIMEOUT_MS ?? 90_000);
const timeoutMS = Number.isFinite(configuredTimeout)
  ? Math.max(10_000, Math.min(configuredTimeout, 180_000)) : 90_000;
const evidence = {
  schemaVersion: 1,
  evidence: "live-Realtime-provider / synthetic-text-input / synthetic-scene-tool-result",
  nativeMicrophoneVerified: false,
  nativePlaybackVerified: false,
  nativeSceneInstallationVerified: false,
  sceneBackendExecutionVerified: false,
  model,
  sessionID,
  startedAt: new Date(startedAt).toISOString(),
  status: "running",
  eventCounts: {},
  turns: [],
};

function check(condition, code) {
  if (!condition) throw Object.assign(new Error(code), { smokeCode: code });
}

function metadataFor(turn, phase) {
  return {
    generation: String(turn.generation), request_id: turn.requestID,
    phase, source: turn.source,
  };
}

function checkMetadata(actual, expected) {
  check(Object.entries(expected).every(([key, value]) => actual?.[key] === value), "response_metadata_mismatch");
}

async function run() {
  let savedConfig = {};
  try { savedConfig = JSON.parse(await readFile(new URL(".local/dev-session.json", root), "utf8")); }
  catch (error) { if (error.code !== "ENOENT") check(false, "invalid_local_development_config"); }
  const baseURL = process.env.ASTRA_SESSION_BASE_URL ?? savedConfig.url ?? "http://127.0.0.1:8787";
  const token = process.env.ASTRA_SESSION_TOKEN ?? process.env.SESSION_ACCESS_TOKEN ?? savedConfig.token;
  const headers = { "Content-Type": "application/json" };
  if (token) headers.Authorization = `Bearer ${token}`;
  const credentialResponse = await fetch(new URL("/realtime/client-secret", baseURL), {
    method: "POST", headers, body: JSON.stringify({ sessionId: sessionID }),
    signal: AbortSignal.timeout(15_000),
  });
  evidence.credentialHTTPStatus = credentialResponse.status;
  check(credentialResponse.ok, "credential_http_failed");
  const credential = await credentialResponse.json();
  check(typeof credential.clientSecret?.value === "string" &&
    typeof credential.clientSecret?.expires_at === "number", "credential_schema_mismatch");
  check(credential.model === model, "credential_model_mismatch");
  check(credential.clientSecret.expires_at * 1000 > Date.now() + 5_000, "credential_expired");
  evidence.credentialLatencyMS = Date.now() - startedAt;

  await new Promise((resolve, reject) => {
    const socket = new WebSocket(`wss://api.openai.com/v1/realtime?model=${model}`, {
      headers: { Authorization: `Bearer ${credential.clientSecret.value}` },
      handshakeTimeout: 15_000,
    });
    let settled = false;
    let turn;
    let phase;
    let activeResponse;
    const timer = setTimeout(() => finish(Object.assign(new Error(), { smokeCode: "smoke_timeout" })), timeoutMS);
    function finish(error) {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      socket.terminate();
      error ? reject(error) : resolve();
    }
    function send(event) { socket.send(JSON.stringify(event)); }
    function createResponse(nextPhase) {
      phase = nextPhase;
      activeResponse = {
        phase, status: "requested", requestedAtMS: Date.now() - startedAt,
        metadataVerified: false, textCharacters: 0, transcriptCharacters: 0,
        audioBytes: 0, audioEvents: 0,
      };
      turn.responses.push(activeResponse);
      send({
        type: "response.create", event_id: `turn_${turn.generation}_${phase}`,
        response: {
          output_modalities: [phase === "tool" ? "text" : turn.outputModality],
          tool_choice: phase === "tool" ? { type: "function", name: "ask_astra" } : "none",
          metadata: metadataFor(turn, phase), max_output_tokens: 512,
        },
      });
    }
    function beginTurn(outputModality) {
      turn = {
        generation: evidence.turns.length + 1,
        requestID: `request-${randomUUID()}`,
        source: outputModality === "text" ? "typed" : "voice",
        inputKind: "synthetic_input_text", outputModality,
        syntheticToolResults: 0, responses: [],
      };
      evidence.turns.push(turn);
      send({
        type: "conversation.item.create", event_id: `turn_${turn.generation}_input`,
        item: {
          type: "message", role: "user",
          content: [{ type: "input_text", text: "Please ask Astra to perform the synthetic scene smoke check. This is synthetic test input, not microphone capture." }],
        },
      });
      createResponse("tool");
    }
    socket.on("message", (raw) => {
      try {
        const event = JSON.parse(raw.toString("utf8"));
        evidence.eventCounts[event.type] = (evidence.eventCounts[event.type] ?? 0) + 1;
        switch (event.type) {
          case "session.created":
            evidence.providerSessionID = event.session.id;
            check(event.session.model === model, "provider_model_mismatch");
            send({
              type: "session.update",
              session: {
                type: "realtime", output_modalities: ["audio"],
                instructions: "You are Astra's conversation layer. For each user turn, call ask_astra exactly once. Never claim a scene changed before the tool result. After the tool result, accurately present its explanation or error in one short sentence without inventing state. Clearly preserve any synthetic-test qualification.",
                tools: [{
                  type: "function", name: "ask_astra",
                  description: "Execute the user's request against Astra's scene agent. Call exactly once per user turn.",
                  parameters: {
                    type: "object", properties: { request: { type: "string" } },
                    required: ["request"], additionalProperties: false,
                  },
                }],
                tool_choice: "auto",
                audio: {
                  input: {
                    format: { type: "audio/pcm", rate: 24_000 },
                    noise_reduction: { type: "near_field" },
                    transcription: { model: "gpt-live-transcribe" },
                    turn_detection: {
                      type: "server_vad", threshold: 0.5, prefix_padding_ms: 300,
                      silence_duration_ms: 450, create_response: false, interrupt_response: true,
                    },
                  },
                  output: { format: { type: "audio/pcm", rate: 24_000 }, voice: "marin" },
                },
              },
            });
            break;
          case "session.updated": {
            check(!turn, "unexpected_session_update");
            const { audio } = event.session;
            check(audio?.input?.format?.rate === 24_000 && audio?.output?.format?.rate === 24_000, "pcm_configuration_mismatch");
            check(audio?.input?.turn_detection?.create_response === false, "manual_response_configuration_mismatch");
            check(audio?.input?.transcription?.model === "gpt-live-transcribe", "transcription_configuration_mismatch");
            evidence.sessionConfigurationVerified = true;
            beginTurn("text");
            break;
          }
          case "response.created":
            check(activeResponse?.status === "requested", "unexpected_response_created");
            checkMetadata(event.response.metadata, metadataFor(turn, phase));
            activeResponse.id = event.response.id;
            activeResponse.status = event.response.status;
            activeResponse.createdAtMS = Date.now() - startedAt;
            break;
          case "response.output_text.delta":
          case "response.output_audio_transcript.delta":
          case "response.output_audio.delta": {
            check(event.response_id === activeResponse?.id, "stale_response_delta");
            if (event.type === "response.output_text.delta") activeResponse.textCharacters += event.delta.length;
            else if (event.type === "response.output_audio_transcript.delta") activeResponse.transcriptCharacters += event.delta.length;
            else {
              const bytes = Buffer.from(event.delta, "base64").byteLength;
              check(bytes % 2 === 0, "invalid_pcm16_chunk");
              activeResponse.audioBytes += bytes;
              activeResponse.audioEvents += 1;
            }
            break;
          }
          case "response.done": {
            const response = event.response;
            check(response.id === activeResponse?.id, "stale_response_done");
            checkMetadata(response.metadata, metadataFor(turn, phase));
            activeResponse.metadataVerified = true;
            activeResponse.status = response.status;
            activeResponse.completedAtMS = Date.now() - startedAt;
            activeResponse.latencyMS = activeResponse.completedAtMS - activeResponse.requestedAtMS;
            // Argument-done events also occur for cancellation. Execution belongs here.
            check(response.status === "completed", "response_not_completed");
            const calls = response.output.filter(item => item.type === "function_call");
            activeResponse.functionCallCount = calls.length;
            if (phase === "tool") {
              check(calls.length === 1 && calls[0].name === "ask_astra", "forced_tool_mismatch");
              const call = calls[0];
              check(call.status === "completed" && typeof call.call_id === "string", "function_call_incomplete");
              const args = JSON.parse(call.arguments);
              check(typeof args.request === "string" && args.request.trim().length > 0 && Object.keys(args).length === 1, "function_arguments_invalid");
              activeResponse.callID = call.call_id;
              check(activeResponse.audioBytes === 0, "tool_phase_emitted_audio");
              send({
                type: "conversation.item.create",
                item: {
                  type: "function_call_output", call_id: call.call_id,
                  output: JSON.stringify({
                    status: "synthetic", requestID: turn.requestID, proposalRequestIDs: [],
                    explanation: "Synthetic scene smoke check complete. No native scene was changed.",
                  }),
                },
              });
              turn.syntheticToolResults += 1;
              createResponse("final");
            } else {
              check(calls.length === 0, "final_response_called_tool");
              if (turn.outputModality === "text") {
                check(activeResponse.textCharacters > 0 && activeResponse.audioBytes === 0, "text_continuation_mismatch");
                beginTurn("audio");
              } else {
                check(activeResponse.audioBytes > 0 && activeResponse.transcriptCharacters > 0, "audio_continuation_mismatch");
                activeResponse.audioDurationMS = Math.round(activeResponse.audioBytes / 48);
                finish();
              }
            }
            break;
          }
          case "error":
            evidence.providerErrorCode = /^[a-z_]{1,80}$/.test(event.error?.code ?? "") ? event.error.code : "unclassified";
            check(false, "provider_error");
        }
      } catch (error) { finish(error); }
    });
    socket.on("error", () => finish(Object.assign(new Error(), { smokeCode: "websocket_transport_failed" })));
    socket.on("close", () => { if (!settled) finish(Object.assign(new Error(), { smokeCode: "websocket_closed_early" })); });
  });
}

try {
  await run();
  evidence.status = "passed";
} catch (error) {
  evidence.status = "failed";
  evidence.failureCode = error.smokeCode ?? "unexpected_failure";
  process.exitCode = 1;
} finally {
  evidence.elapsedMS = Date.now() - startedAt;
  await mkdir(new URL("docs/evidence/", root), { recursive: true });
  await writeFile(output, `${JSON.stringify(evidence, null, 2)}\n`);
  console.log(JSON.stringify({ status: evidence.status, failureCode: evidence.failureCode, elapsedMS: evidence.elapsedMS, evidencePath: fileURLToPath(output) }));
}
