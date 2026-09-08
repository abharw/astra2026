import assert from "node:assert/strict";
import test from "node:test";
import { JsonlLogger } from "../src/diagnostics.js";
import { ModelEvent, OpenAIResponsesTransport } from "../src/astra/client.js";

test("Responses request has one strict tool, a stable explicit cache prefix and private context", async () => {
  let sent: any;
  const transport = new OpenAIResponsesTransport("test", async (_url, init) => {
    sent = JSON.parse(init?.body as string);
    return new Response(`data: ${JSON.stringify({ type: "response.completed" })}\n\n`);
  });
  for await (const _event of transport.stream({ requestId: "do-not-send-in-prompt", text: "Move the optical mount", selectionNodeIds: ["optics.mount"], scene: { nodes: [] }, signal: new AbortController().signal })) { /* drain */ }
  assert.equal(sent.model, "gpt-6-astra");
  assert.equal(sent.tool_choice, "required");
  assert.equal(sent.parallel_tool_calls, false);
  assert.equal(sent.tools.length, 1);
  assert.equal(sent.tools[0].strict, true);
  assert.deepEqual(sent.prompt_cache_options, { mode: "explicit", ttl: "30m" });
  assert.equal(sent.input[0].role, "developer");
  assert.deepEqual(sent.input[0].content[0].prompt_cache_breakpoint, { mode: "explicit" });
  assert.equal(sent.input[1].role, "user");
  assert.equal(sent.input[1].content[0].prompt_cache_breakpoint, undefined);
  assert.equal(sent.instructions, undefined);
  assert.equal(sent.store, false);
  assert.doesNotMatch(JSON.stringify(sent), /do-not-send-in-prompt/);
});

test("stream phases and numeric usage are logged without retaining private arguments or text", async () => {
  const lines: string[] = [];
  const logger = new JsonlLogger(undefined, { log: (line) => lines.push(line) });
  const proposal = JSON.stringify({ mode: "explanation", explanation: "private explanation", scopeParentNodeId: null, operations: [] });
  const events = [
    { type: "response.created" },
    { type: "response.function_call_arguments.delta", delta: "private argument delta" },
    { type: "response.function_call_arguments.delta", delta: "more private arguments" },
    { type: "response.output_item.done", item: { type: "function_call", name: "propose_scene", arguments: proposal } },
    { type: "response.completed", response: { usage: { input_tokens: 2_000, output_tokens: 200, input_tokens_details: { cached_tokens: 1_100, cache_write_tokens: 10 }, output_tokens_details: { reasoning_tokens: 30 } } } }
  ];
  const sse = events.map((event) => `data: ${JSON.stringify(event)}\n\n`).join("");
  const transport = new OpenAIResponsesTransport("test", async () => new Response(sse), logger);
  const received: ModelEvent[] = [];
  for await (const event of transport.stream({ requestId: "correlation", text: "private user prompt", selectionNodeIds: [], scene: { nodes: [] }, signal: new AbortController().signal })) received.push(event);
  assert.deepEqual(received.map((event) => event.type), ["progress", "function_call", "done"]);
  const records = lines.map((line) => JSON.parse(line));
  assert.equal(records.filter((record) => record.event === "first_arguments_delta").length, 1);
  assert.equal(records.find((record) => record.event === "first_provider_event").eventType, "response.created");
  const usage = records.find((record) => record.event === "response_completed");
  assert.equal(usage.inputTokens, 2_000);
  assert.equal(usage.outputTokens, 200);
  assert.equal(usage.cachedInputTokens, 1_100);
  assert.equal(usage.cacheWriteTokens, 10);
  assert.equal(usage.reasoningTokens, 30);
  assert.doesNotMatch(lines.join("\n"), /private|more private/);
  logger.log("test", "malicious_metrics", { inputTokens: "sk_private", outputTokens: -1, cachedInputTokens: Infinity, authToken: "secret", inputBytes: 123 });
  assert.deepEqual(JSON.parse(lines.at(-1)!), { timestamp: JSON.parse(lines.at(-1)!).timestamp, component: "test", event: "malicious_metrics", level: "info", inputBytes: 123 });
});
