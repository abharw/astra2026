#!/usr/bin/env node

import { createRequire } from "node:module";

const require = createRequire(import.meta.url);
const WebSocket = require("../../backend/node_modules/ws");

const baseURL = process.env.ASTRA_SESSION_BASE_URL ?? "http://127.0.0.1:8787";
const accessToken = process.env.ASTRA_SESSION_TOKEN ?? process.env.SESSION_ACCESS_TOKEN;
const sessionID = `realtime-smoke-${crypto.randomUUID()}`;
const timeoutMilliseconds = Number(process.env.REALTIME_SMOKE_TIMEOUT_MS ?? 30_000);

const bootstrapHeaders = { "Content-Type": "application/json" };
if (accessToken) bootstrapHeaders.Authorization = `Bearer ${accessToken}`;

const credentialResponse = await fetch(new URL("/realtime/client-secret", baseURL), {
  method: "POST",
  headers: bootstrapHeaders,
  body: JSON.stringify({ sessionId: sessionID }),
});

if (!credentialResponse.ok) {
  const detail = (await credentialResponse.text()).slice(0, 500);
  throw new Error(`credential endpoint returned HTTP ${credentialResponse.status}: ${detail}`);
}

const credential = await credentialResponse.json();
if (
  typeof credential?.clientSecret?.value !== "string" ||
  typeof credential?.clientSecret?.expires_at !== "number" ||
  typeof credential?.model !== "string"
) {
  throw new Error("credential endpoint response does not match the native client contract");
}

const eventCounts = new Map();
let audioBytes = 0;
let audioEvents = 0;
let configuredInputRate;
let configuredOutputRate;
let configuredTranscription;
let configuredCreateResponse;
let responseStatus;

const result = await new Promise((resolve, reject) => {
  const realtimeURL = `wss://api.openai.com/v1/realtime?model=${encodeURIComponent(credential.model)}`;
  const socket = new WebSocket(realtimeURL, {
    headers: { Authorization: `Bearer ${credential.clientSecret.value}` },
  });
  let settled = false;

  const timer = setTimeout(() => finish(new Error("Realtime smoke timed out")), timeoutMilliseconds);

  function finish(error) {
    if (settled) return;
    settled = true;
    clearTimeout(timer);
    socket.close();
    if (error) reject(error);
    else resolve();
  }

  socket.on("message", raw => {
    let event;
    try {
      event = JSON.parse(raw.toString("utf8"));
    } catch {
      finish(new Error("Realtime returned a non-JSON event"));
      return;
    }

    eventCounts.set(event.type, (eventCounts.get(event.type) ?? 0) + 1);
    switch (event.type) {
      case "session.created":
        socket.send(JSON.stringify({
          type: "session.update",
          session: {
            type: "realtime",
            output_modalities: ["audio"],
            instructions: "Speak only text explicitly supplied by this application.",
            audio: {
              input: {
                format: { type: "audio/pcm", rate: 24_000 },
                noise_reduction: { type: "near_field" },
                transcription: { model: "gpt-live-transcribe" },
                turn_detection: {
                  type: "server_vad",
                  threshold: 0.5,
                  prefix_padding_ms: 300,
                  silence_duration_ms: 450,
                  create_response: false,
                  interrupt_response: true,
                },
              },
              output: {
                format: { type: "audio/pcm", rate: 24_000 },
                voice: "marin",
              },
            },
          },
        }));
        break;

      case "session.updated":
        configuredInputRate = event.session?.audio?.input?.format?.rate;
        configuredOutputRate = event.session?.audio?.output?.format?.rate;
        configuredTranscription = event.session?.audio?.input?.transcription?.model;
        configuredCreateResponse = event.session?.audio?.input?.turn_detection?.create_response;
        socket.send(JSON.stringify({
          type: "conversation.item.create",
          item: {
            type: "message",
            role: "user",
            content: [{
              type: "input_text",
              text: "Synthetic text smoke input. This is not captured microphone audio.",
            }],
          },
        }));
        socket.send(JSON.stringify({
          type: "response.create",
          response: {
            output_modalities: ["audio"],
            instructions: "Say exactly: Astra Realtime smoke test complete.",
          },
        }));
        break;

      case "response.output_audio.delta": {
        const bytes = Buffer.from(event.delta ?? "", "base64");
        if (bytes.byteLength % 2 !== 0) {
          finish(new Error("Realtime emitted an odd-length PCM16 audio chunk"));
          return;
        }
        audioBytes += bytes.byteLength;
        audioEvents += 1;
        break;
      }

      case "response.done":
        responseStatus = event.response?.status;
        if (responseStatus !== "completed") {
          finish(new Error(`Realtime response finished with status ${responseStatus ?? "unknown"}`));
          return;
        }
        if (configuredInputRate !== 24_000 || configuredOutputRate !== 24_000) {
          finish(new Error("Realtime did not accept 24 kHz PCM input/output configuration"));
          return;
        }
        if (configuredTranscription !== "gpt-live-transcribe" || configuredCreateResponse !== false) {
          finish(new Error("Realtime did not accept the native transcription/VAD configuration"));
          return;
        }
        if (audioBytes === 0 || audioEvents === 0) {
          finish(new Error("Realtime completed without audio deltas"));
          return;
        }
        finish();
        break;

      case "error":
        finish(new Error(`Realtime error: ${event.error?.message ?? "unknown"}`));
        break;
    }
  });

  socket.on("error", () => finish(new Error("Realtime WebSocket transport failed")));
  socket.on("close", () => {
    if (!settled) finish(new Error("Realtime WebSocket closed before response completion"));
  });
});

void result;
const estimatedAudioMilliseconds = Math.round(audioBytes / 2 / 24_000 * 1_000);
console.log(JSON.stringify({
  evidence: "synthetic-text/live-Realtime; not native microphone or device playback proof",
  model: credential.model,
  clientSecretExpiresAt: credential.clientSecret.expires_at,
  configuredInputRate,
  configuredOutputRate,
  configuredTranscription,
  configuredCreateResponse,
  responseStatus,
  audioEvents,
  audioBytes,
  estimatedAudioMilliseconds,
  eventNames: [...eventCounts.keys()],
}, null, 2));
