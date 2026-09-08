import assert from "node:assert/strict";
import test from "node:test";
import { ASTRA_AUTHORING_TOOL, authoringTool } from "../src/astra/authoring-tool.js";
import { ModelRequest, OpenAIResponsesTransport, RecentIllustration, formatUserInput } from "../src/astra/client.js";
import { ASTRA_ILLUSTRATION_INSTRUCTIONS, ASTRA_SYSTEM_INSTRUCTIONS } from "../src/astra/instructions.js";
import { JsonObject, ProtocolError, asObject } from "../src/json.js";
import { IllustrationIntent, normalizeProposal, parseAuthoringProposal } from "../src/normalizer.js";

const intent: IllustrationIntent = { brief: "Draw a labelled cutaway explaining the optical path.", componentNodeIds: ["optics.mount"], sourceArtifactId: null };
const explanation = { mode: "explanation", explanation: "I am preparing an illustrative cutaway.", scopeParentNodeId: null, operations: [] };

function request(options: Partial<ModelRequest> = {}): ModelRequest {
  return { requestId: "private-id", text: "Explain this component", selectionNodeIds: ["optics.mount"], scene: { nodes: [] }, signal: new AbortController().signal, ...options };
}

async function sentRequest(options: Partial<ModelRequest> = {}): Promise<JsonObject> {
  let sent: JsonObject | undefined;
  const transport = new OpenAIResponsesTransport("test", async (_url, init) => {
    sent = asObject(JSON.parse(init?.body as string), "request");
    return new Response(`data: ${JSON.stringify({ type: "response.completed" })}\n\n`);
  });
  for await (const _event of transport.stream(request(options))) { /* drain */ }
  assert.ok(sent);
  return sent;
}

test("illustrations preserve one strict tool and the exact disabled request", async () => {
  const disabled = await sentRequest();
  assert.deepEqual(await sentRequest({ illustrationEnabled: false, recentIllustrations: [{ artifactId: "private-artifact", componentNodeIds: ["optics.mount"], sourceRevision: 0, brief: "Private prior request" }] }), disabled);
  const enabled = await sentRequest({ illustrationEnabled: true });
  const disabledTools = disabled.tools as JsonObject[];
  const enabledTools = enabled.tools as JsonObject[];
  assert.deepEqual(disabledTools, [ASTRA_AUTHORING_TOOL]);
  assert.equal(enabledTools.length, 1);
  assert.equal(enabledTools[0]!.name, "propose_scene");
  assert.equal(enabledTools[0]!.strict, true);
  assert.equal(enabled.parallel_tool_calls, false);
  assert.equal(enabled.tool_choice, "required");
  const parameters = asObject(enabledTools[0]!.parameters, "parameters");
  const properties = asObject(parameters.properties, "properties");
  assert.deepEqual(parameters.required, ["mode", "explanation", "scopeParentNodeId", "operations", "illustration"]);
  const schema = asObject(properties.illustration, "illustration schema");
  const alternatives = schema.anyOf as JsonObject[];
  assert.deepEqual(alternatives[1], { type: "null" });
  assert.deepEqual(alternatives[0]!.required, ["brief", "componentNodeIds", "sourceArtifactId"]);
  assert.equal(alternatives[0]!.additionalProperties, false);
  assert.doesNotMatch(JSON.stringify(disabled), /recentIllustrations|private-artifact/);
  assert.match(JSON.stringify(enabled), /recentIllustrations/);
  assert.ok(JSON.stringify(enabled).includes(JSON.stringify(ASTRA_ILLUSTRATION_INSTRUCTIONS).slice(1, -1)));
  assert.ok(JSON.stringify(disabled).includes(JSON.stringify(ASTRA_SYSTEM_INSTRUCTIONS).slice(1, -1)));
});

test("extending one tool cannot mutate the legacy schema or subsequent requests", () => {
  const before = JSON.stringify(ASTRA_AUTHORING_TOOL);
  const enabled = authoringTool(true);
  asObject(enabled.parameters, "parameters").required = [];
  asObject(asObject(enabled.parameters, "parameters").properties, "properties").mode = null;
  assert.equal(JSON.stringify(ASTRA_AUTHORING_TOOL), before);
  assert.deepEqual(authoringTool().parameters, ASTRA_AUTHORING_TOOL.parameters);
  assert.notDeepEqual(authoringTool(true), enabled);
});

test("model illustration history is gated, capped and projects metadata without paths or image bytes", () => {
  const history: RecentIllustration[] = Array.from({ length: 6 }, (_, index) => ({
    artifactId: `sha256:${String(index).repeat(64)}`, componentNodeIds: ["optics.mount"], sourceRevision: 4, brief: `Prior diagram ${index}`,
    path: "/private/artifact.png", imageBytes: "private-image-bytes", url: "https://private.example/image"
  }));
  const disabled = formatUserInput(request({ recentIllustrations: history }));
  assert.equal(JSON.parse(disabled).recentIllustrations, undefined);
  const enabled = formatUserInput(request({ illustrationEnabled: true, recentIllustrations: history }));
  const context = JSON.parse(enabled);
  assert.deepEqual(context.recentIllustrations, history.slice(-4).map(({ artifactId, componentNodeIds, sourceRevision, brief }) => ({ artifactId, componentNodeIds, sourceRevision, brief })));
  assert.doesNotMatch(enabled, /private-image-bytes|private\.example|\/private\//);
});

test("legacy missing and explicit null illustration proposals normalize identically", () => {
  const legacy = parseAuthoringProposal(explanation);
  assert.equal(Object.hasOwn(legacy, "illustration"), false);
  const explicitNull = parseAuthoringProposal({ ...explanation, illustration: null });
  assert.equal(explicitNull.illustration, null);
  const normalized = normalizeProposal("legacy", legacy, new Set());
  assert.deepEqual(normalizeProposal("null", explicitNull, new Set()), normalized);
  assert.equal(Object.hasOwn(normalized, "illustration"), false);
});

test("admitted illustrations bind to observed components and preserve refinement identity", () => {
  const refined = { ...intent, brief: `  ${intent.brief}  `, componentNodeIds: [...intent.componentNodeIds], sourceArtifactId: `sha256:${"a".repeat(64)}` };
  const parsed = parseAuthoringProposal({ ...explanation, illustration: refined });
  const normalized = normalizeProposal("illustration", parsed, new Set(["optics.mount"]));
  assert.deepEqual(normalized.illustration, { ...refined, brief: intent.brief });
  assert.deepEqual(normalized.operations, []);
  assert.throws(() => normalizeProposal("invented", parsed, new Set(["other.component"])), /observed node IDs/);
  refined.componentNodeIds.push("later-change");
  assert.deepEqual(normalized.illustration!.componentNodeIds, ["optics.mount"]);
});

test("illustrations cannot accompany a patch, generation, operations, or a reserved scope", () => {
  for (const mode of ["patch", "generation"]) {
    assert.throws(() => normalizeProposal("mixed", parseAuthoringProposal({ ...explanation, mode, operations: [{ kind: "setVisibility", nodeRef: "optics.mount", visible: true }], illustration: intent }), new Set(["optics.mount"])), /illustrations require explanation mode/);
  }
  assert.throws(() => normalizeProposal("operations", parseAuthoringProposal({ ...explanation, operations: [{ kind: "setVisibility", nodeRef: "optics.mount", visible: true }], illustration: intent }), new Set(["optics.mount"])), /explanations require zero operations/);
  assert.throws(() => normalizeProposal("scope", parseAuthoringProposal({ ...explanation, scopeParentNodeId: "optics.mount", illustration: intent }), new Set(["optics.mount"])), /cannot reserve a generation scope/);
});

test("illustration validation enforces UTF-8 bytes, unique bounded bindings, and a strict refinement object", () => {
  const valid = { ...intent, brief: "é".repeat(1_000) };
  assert.equal(parseAuthoringProposal({ ...explanation, illustration: valid }).illustration?.brief, valid.brief);
  const invalid: unknown[] = [
    { ...intent, brief: "é".repeat(1_001) }, { ...intent, brief: " " }, { ...intent, brief: 42 },
    { ...intent, componentNodeIds: [] }, { ...intent, componentNodeIds: ["optics.mount", "optics.mount"] },
    { ...intent, componentNodeIds: Array.from({ length: 17 }, (_, index) => `node${index}`) },
    { ...intent, componentNodeIds: [""] }, { ...intent, componentNodeIds: [42] },
    { ...intent, sourceArtifactId: "" }, { ...intent, sourceArtifactId: 42 }, { ...intent, sourceArtifactId: undefined },
    { ...intent, extra: "not allowed" }, [], "invalid"
  ];
  for (const illustration of invalid) assert.throws(() => parseAuthoringProposal({ ...explanation, illustration }), ProtocolError);
  const componentNodeIds = Array.from({ length: 16 }, (_, index) => `node${index}`);
  const parsed = parseAuthoringProposal({ ...explanation, illustration: { ...intent, componentNodeIds } });
  assert.equal(normalizeProposal("maximum", parsed, new Set(componentNodeIds)).illustration?.componentNodeIds.length, 16);
});
