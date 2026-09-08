import { JsonObject, isObject } from "../json.js";
import { ASTRA_AUTHORING_TOOL } from "./authoring-tool.js";
import { ASTRA_SYSTEM_INSTRUCTIONS } from "./instructions.js";
import { DiagnosticLogger, safeError } from "../diagnostics.js";
import { RecentTurn } from "./conversation-context.js";
import { sceneContext } from "./scene-context.js";

export interface ModelRequest {
  requestId: string;
  text: string;
  selectionNodeIds: string[];
  scene: JsonObject;
  recentTurns?: RecentTurn[];
  signal: AbortSignal;
}

export interface FunctionCallEvent { type: "function_call"; name: string; arguments: string }
export interface TextEvent { type: "text"; delta: string }
export interface DoneEvent { type: "done" }
export interface ProgressEvent { type: "progress"; stage: "generating" }
export type ModelEvent = FunctionCallEvent | TextEvent | DoneEvent | ProgressEvent;

export interface ModelTransport {
  stream(request: ModelRequest): AsyncIterable<ModelEvent>;
}

/** Minimal Responses API adapter. It yields one canonical completed tool event per item. */
export class OpenAIResponsesTransport implements ModelTransport {
  constructor(private readonly apiKey: string, private readonly fetchImpl: typeof fetch = fetch, private readonly logger?: DiagnosticLogger) {}

  async *stream(request: ModelRequest): AsyncIterable<ModelEvent> {
    const startedAt = Date.now();
    const input = formatUserInput(request);
    this.logger?.log("astra", "fetch_start", { requestId: request.requestId, inputBytes: Buffer.byteLength(input, "utf8"), sceneBytes: Buffer.byteLength(JSON.stringify(request.scene), "utf8"), historyTurns: request.recentTurns?.length ?? 0 });
    let response: Response;
    try { response = await this.fetchImpl("https://api.openai.com/v1/responses", {
      method: "POST",
      signal: request.signal,
      headers: {
        authorization: `Bearer ${this.apiKey}`,
        "content-type": "application/json",
        accept: "text/event-stream"
      },
      body: JSON.stringify({
        model: "gpt-6-astra",
        reasoning: { effort: "low" },
        stream: true,
        store: false,
        tool_choice: "required",
        parallel_tool_calls: false,
        max_output_tokens: 4_096,
        prompt_cache_options: { mode: "explicit", ttl: "30m" },
        tools: [ASTRA_AUTHORING_TOOL],
        input: [
          { role: "developer", content: [{ type: "input_text", text: ASTRA_SYSTEM_INSTRUCTIONS, prompt_cache_breakpoint: { mode: "explicit" } }] },
          { role: "user", content: [{ type: "input_text", text: input }] }
        ]
      })
    }); } catch (error) {
      this.logger?.log("astra", "fetch_error", { requestId: request.requestId, durationMs: Date.now() - startedAt, safeError: safeError(error) }, "warn");
      throw error;
    }
    this.logger?.log("astra", "fetch_status", { requestId: request.requestId, status: response.status, durationMs: Date.now() - startedAt });
    if (!response.ok || !response.body) {
      await response.text(); // Consume the stream without retaining or logging provider content.
      throw new Error(`Responses request failed (${response.status})`);
    }
    const decoder = new TextDecoder();
    let pending = "";
    let sawFirstEvent = false;
    let sawArguments = false;
    const observe = (payload: string): ModelEvent | undefined => {
      let raw: unknown;
      try { raw = JSON.parse(payload); } catch { return undefined; }
      if (!isObject(raw) || typeof raw.type !== "string") return undefined;
      if (!sawFirstEvent) {
        sawFirstEvent = true;
        this.logger?.log("astra", "first_provider_event", { requestId: request.requestId, durationMs: Date.now() - startedAt, eventType: raw.type });
      }
      if (raw.type === "response.function_call_arguments.delta" && !sawArguments) {
        sawArguments = true;
        this.logger?.log("astra", "first_arguments_delta", { requestId: request.requestId, durationMs: Date.now() - startedAt });
        return { type: "progress", stage: "generating" };
      }
      if (raw.type === "response.completed") {
        const usage = isObject(raw.response) && isObject(raw.response.usage) ? raw.response.usage : {};
        const details = isObject(usage.input_tokens_details) ? usage.input_tokens_details : {};
        const outputDetails = isObject(usage.output_tokens_details) ? usage.output_tokens_details : {};
        this.logger?.log("astra", "response_completed", {
          requestId: request.requestId, durationMs: Date.now() - startedAt,
          inputTokens: numeric(usage.input_tokens), outputTokens: numeric(usage.output_tokens),
          cachedInputTokens: numeric(details.cached_tokens), cacheWriteTokens: numeric(details.cache_write_tokens),
          reasoningTokens: numeric(outputDetails.reasoning_tokens)
        });
      }
      const event = parseProviderEvent(raw);
      if (event?.type === "function_call") this.logger?.log("astra", "function_arguments_done", { requestId: request.requestId, durationMs: Date.now() - startedAt, bytes: Buffer.byteLength(event.arguments, "utf8") });
      return event;
    };
    for await (const chunk of response.body as unknown as AsyncIterable<Uint8Array>) {
      pending += decoder.decode(chunk, { stream: true });
      const frames = pending.split("\n\n");
      pending = frames.pop() ?? "";
      for (const frame of frames) {
        const payload = frame.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
        if (!payload || payload === "[DONE]") continue;
        const event = observe(payload);
        if (event) yield event;
      }
    }
    if (!pending.trim()) return;
    const payload = pending.split("\n").filter((line) => line.startsWith("data:")).map((line) => line.slice(5).trim()).join("\n");
    if (payload && payload !== "[DONE]") {
      const event = observe(payload);
      if (event) yield event;
    }
  }
}

function parseProviderEvent(event: JsonObject): ModelEvent | undefined {
  if (event.type === "response.output_text.delta" && typeof event.delta === "string") return { type: "text", delta: event.delta };
  // Arguments-done is an intermediate stream event. The same item is repeated in
  // output_item.done, which is our only executable completion boundary.
  if (event.type === "response.output_item.done" && isObject(event.item) && event.item.type === "function_call" && typeof event.item.name === "string" && typeof event.item.arguments === "string") return { type: "function_call", name: event.item.name, arguments: event.item.arguments };
  if (event.type === "response.completed") return { type: "done" };
  if (event.type === "error") throw new Error("Responses stream returned an error event");
  return undefined;
}

export function formatUserInput(request: ModelRequest): string {
  // Every scene node remains present. The context factors repeated metadata; it
  // never truncates tail nodes or rounds transforms. Request identity stays in code.
  return JSON.stringify({ userRequest: request.text, selectionNodeIds: request.selectionNodeIds, recentTurns: request.recentTurns ?? [], acceptedScene: sceneContext(request.scene) });
}

function numeric(value: unknown): number | undefined { return typeof value === "number" && Number.isFinite(value) ? value : undefined; }
