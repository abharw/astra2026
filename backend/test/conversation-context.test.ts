import assert from "node:assert/strict";
import test from "node:test";
import { RecentTurn, SceneConversation } from "../src/astra/conversation-context.js";

function turn(index: number, text = `Question ${index}`): RecentTurn {
  return {
    userRequest: text,
    selectionNodeIds: ["server01", "removed_server"],
    result: { status: "installed", explanation: `Result ${index}`, affectedNodeIds: ["server01", "removed_arrow"] }
  };
}

function append(conversation: SceneConversation, value: RecentTurn): void {
  conversation.append(value, value.result);
}

test("conversation retains the six newest whole outcomes in order", () => {
  const conversation = new SceneConversation();
  for (let index = 0; index < 9; index += 1) append(conversation, turn(index));
  const recent = conversation.context(new Set(["server01"]));
  assert.equal(recent.length, 6);
  assert.deepEqual(recent.map((item) => item.userRequest), [3, 4, 5, 6, 7, 8].map((index) => `Question ${index}`));
  assert.deepEqual(recent.map((item) => item.result.explanation), [3, 4, 5, 6, 7, 8].map((index) => `Result ${index}`));
});

test("conversation enforces its UTF-8 byte limit by removing whole oldest turns", () => {
  const conversation = new SceneConversation();
  const values = Array.from({ length: 6 }, (_, index) => turn(index, `${index}: ${"架".repeat(1_400)}`));
  for (const value of values) append(conversation, value);
  const recent = conversation.context(new Set(["server01", "removed_server", "removed_arrow"]));
  assert.ok(recent.length > 0 && recent.length < 6);
  assert.ok(Buffer.byteLength(JSON.stringify(recent), "utf8") <= 12 * 1024);
  assert.deepEqual(recent, values.slice(-recent.length));
});

test("an individually oversized turn is omitted without truncation or evicting useful history", () => {
  const conversation = new SceneConversation();
  append(conversation, turn(1));
  const ids = new Set(["server01", "removed_server", "removed_arrow"]);
  const previous = conversation.context(ids);
  append(conversation, turn(2, "🧠".repeat(4_000)));
  assert.deepEqual(conversation.context(ids), previous);
  append(conversation, turn(3));
  assert.deepEqual(conversation.context(ids).map((item) => item.userRequest), ["Question 1", "Question 3"]);
});

test("context prunes removed selected and affected IDs while retaining truthful outcome text", () => {
  const conversation = new SceneConversation();
  append(conversation, turn(1));
  assert.deepEqual(conversation.context(new Set(["server01"])), [{
    userRequest: "Question 1", selectionNodeIds: ["server01"],
    result: { status: "installed", explanation: "Result 1", affectedNodeIds: ["server01"] }
  }]);
  const emptyScene = conversation.context(new Set());
  assert.deepEqual(emptyScene[0]?.selectionNodeIds, []);
  assert.deepEqual(emptyScene[0]?.result.affectedNodeIds, []);
  assert.equal(emptyScene[0]?.result.explanation, "Result 1");
});

test("recorded history is isolated from caller mutation and clear removes every outcome", () => {
  const conversation = new SceneConversation();
  const original = turn(1);
  append(conversation, original);
  original.selectionNodeIds.push("injected");
  original.result.explanation = "changed outside the conversation";
  original.result.affectedNodeIds.push("injected");
  const ids = new Set(["server01", "injected"]);
  const read = conversation.context(ids);
  assert.deepEqual(read[0]?.selectionNodeIds, ["server01"]);
  assert.equal(read[0]?.result.explanation, "Result 1");
  read[0]!.result.affectedNodeIds.push("injected");
  read[0]!.result.explanation = "changed returned result";
  assert.deepEqual(conversation.context(ids)[0]?.result.affectedNodeIds, ["server01"]);
  assert.equal(conversation.context(ids)[0]?.result.explanation, "Result 1");
  conversation.clear();
  assert.deepEqual(conversation.context(ids), []);
});
