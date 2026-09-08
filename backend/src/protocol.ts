import { asObject, isObject, isString, JsonObject, JsonValue, ProtocolError, rejectUnknown, requireArray, requireInteger, requireString } from "./json.js";
import { AvailableAssetDetail, parseAvailableAssetDetails } from "./asset-details.js";

export const PROTOCOL_VERSION = 1;
export const MAX_WIRE_BYTES = 256 * 1024;
export const MAX_OUTGOING_BUFFER_BYTES = 1024 * 1024;

export interface SessionHello {
  type: "session.hello";
  protocolVersion: number;
  sessionId: string;
  sceneId: string;
  revision: number;
  intentEpoch: number;
  sceneSchemaVersions: number[];
  geometrySemanticsVersions: number[];
  capabilities: string[];
  authToken?: string;
}

export interface PhoneSnapshot {
  type: "phone.snapshot";
  sceneId: string;
  revision: number;
  intentEpoch: number;
  document: JsonObject;
  availableAssetDetails?: AvailableAssetDetail[];
}

export interface UserRequest {
  type: "user.request";
  requestId: string;
  text: string;
  selection?: { nodeIds: string[] };
}

export interface CancelRequest { type: "session.cancel"; requestId: string }
export interface UserStop { type: "user.stop"; requestId: string; sceneId: string; intentEpoch: number }
export interface UserUndo { type: "user.undo"; requestId: string; sceneId: string; intentEpoch: number }

export interface SceneReceipt {
  type: "scene.receipt";
  protocolVersion: number;
  sceneId: string;
  generationId?: string;
  requestId: string;
  sequence?: number;
  status: "installed" | "rejected";
  revision: number;
  affectedNodeIds: string[];
  rejection?: JsonObject;
}

export interface GenerationReceipt {
  type: "generation.receipt";
  protocolVersion: number;
  sceneId: string;
  generationId: string;
  requestId: string;
  status: "accepted" | "completed" | "rejected";
  revision: number;
  committedSequence: number;
  rejection?: JsonObject;
}

export interface IllustrationControl { type: "illustration.cancel" | "illustration.retry"; jobId: string }

export type ClientEnvelope = IllustrationControl | SessionHello | PhoneSnapshot | UserRequest | CancelRequest | UserStop | UserUndo | SceneReceipt | GenerationReceipt;

export function parseClientEnvelope(value: unknown): ClientEnvelope {
  const object = asObject(value, "message");
  const type = requireString(object, "type", 64);
  switch (type) {
    case "session.hello": return parseHello(object);
    case "phone.snapshot": {
      rejectUnknown(object, ["type", "sceneId", "revision", "intentEpoch", "document", "availableAssetDetails"]);
      const document = asObject(object.document, "document");
      return {
      type,
      sceneId: requireString(object, "sceneId", 256),
      revision: requireInteger(object, "revision"),
      intentEpoch: requireInteger(object, "intentEpoch"),
      document,
      ...(object.availableAssetDetails === undefined ? {} : { availableAssetDetails: parseAvailableAssetDetails(object.availableAssetDetails, document) })
    };
    }
    case "user.request": return parseUserRequest(object);
    case "illustration.cancel": case "illustration.retry":
      rejectUnknown(object, ["type", "jobId"]);
      return { type, jobId: requireString(object, "jobId", 128) };
    case "session.cancel":
      rejectUnknown(object, ["type", "requestId"]);
      return { type, requestId: requireString(object, "requestId", 256) };
    case "user.stop": return parseIntentControl(type, object);
    case "user.undo": return parseIntentControl(type, object);
    case "scene.receipt": return parseReceipt(object);
    case "generation.receipt": return parseGenerationReceipt(object);
    default: throw new ProtocolError(`unsupported message type: ${type}`, "unsupported_type");
  }
}

function parseGenerationReceipt(object: JsonObject): GenerationReceipt {
  rejectUnknown(object, ["type", "protocolVersion", "sceneId", "generationId", "requestId", "status", "revision", "committedSequence", "rejection"]);
  const status = requireString(object, "status", 32);
  if (status !== "accepted" && status !== "completed" && status !== "rejected") throw new ProtocolError("generation.receipt status is invalid");
  const rejection = parseRejection(object.rejection);
  return { type: "generation.receipt", protocolVersion: requireInteger(object, "protocolVersion"), sceneId: requireString(object, "sceneId", 256), generationId: requireString(object, "generationId", 256), requestId: requireString(object, "requestId", 256), status, revision: requireInteger(object, "revision"), committedSequence: requireInteger(object, "committedSequence"), rejection };
}

function parseIntentControl(type: "user.stop" | "user.undo", object: JsonObject): UserStop | UserUndo {
  rejectUnknown(object, ["type", "requestId", "sceneId", "intentEpoch"]);
  return { type, requestId: requireString(object, "requestId", 256), sceneId: requireString(object, "sceneId", 256), intentEpoch: requireInteger(object, "intentEpoch") };
}

function parseHello(object: JsonObject): SessionHello {
  rejectUnknown(object, ["type", "protocolVersion", "sessionId", "sceneId", "revision", "intentEpoch", "sceneSchemaVersions", "geometrySemanticsVersions", "capabilities", "authToken"]);
  const schemaVersions = requireArray(object, "sceneSchemaVersions", 16);
  const geometryVersions = requireArray(object, "geometrySemanticsVersions", 16);
  const capabilities = requireArray(object, "capabilities", 128);
  const authToken = object.authToken;
  if (authToken !== undefined && !isString(authToken)) throw new ProtocolError("authToken must be a string");
  if (!schemaVersions.every(Number.isSafeInteger) || !geometryVersions.every(Number.isSafeInteger) || !capabilities.every(isString)) {
    throw new ProtocolError("hello version arrays and capabilities are malformed");
  }
  return {
    type: "session.hello", protocolVersion: requireInteger(object, "protocolVersion"),
    sessionId: requireString(object, "sessionId", 256), sceneId: requireString(object, "sceneId", 256),
    revision: requireInteger(object, "revision"), intentEpoch: requireInteger(object, "intentEpoch"),
    sceneSchemaVersions: schemaVersions as number[], geometrySemanticsVersions: geometryVersions as number[],
    capabilities: capabilities as string[], authToken
  };
}

function parseUserRequest(object: JsonObject): UserRequest {
  rejectUnknown(object, ["type", "requestId", "text", "selection"]);
  const selection = object.selection;
  if (selection === undefined) return { type: "user.request", requestId: requireString(object, "requestId", 256), text: requireString(object, "text", 12_000) };
  const selected = asObject(selection, "selection");
  const nodeIds = requireArray(selected, "nodeIds", 128);
  if (!nodeIds.every(isString)) throw new ProtocolError("selection.nodeIds must contain strings");
  return { type: "user.request", requestId: requireString(object, "requestId", 256), text: requireString(object, "text", 12_000), selection: { nodeIds: nodeIds as string[] } };
}

function parseReceipt(object: JsonObject): SceneReceipt {
  rejectUnknown(object, ["type", "protocolVersion", "sceneId", "generationId", "requestId", "sequence", "status", "revision", "affectedNodeIds", "rejection"]);
  const status = requireString(object, "status", 32);
  if (status !== "installed" && status !== "rejected") throw new ProtocolError("scene.receipt status is invalid");
  const ids = requireArray(object, "affectedNodeIds", 2_000);
  if (!ids.every(isString)) throw new ProtocolError("affectedNodeIds must contain strings");
  const generationId = object.generationId;
  const sequence = object.sequence;
  const rejection = parseRejection(object.rejection);
  if (generationId !== undefined && !isString(generationId)) throw new ProtocolError("generationId must be a string");
  if (sequence !== undefined && (typeof sequence !== "number" || !Number.isSafeInteger(sequence) || sequence < 1)) throw new ProtocolError("sequence must be a positive safe integer");
  return {
    type: "scene.receipt", protocolVersion: requireInteger(object, "protocolVersion"), sceneId: requireString(object, "sceneId", 256),
    generationId, requestId: requireString(object, "requestId", 256), sequence: sequence as number | undefined, status, revision: requireInteger(object, "revision"),
    affectedNodeIds: ids as string[], rejection
  };
}

function parseRejection(value: JsonValue | undefined): JsonObject | undefined {
  if (value === undefined) return undefined;
  const rejection = asObject(value, "rejection");
  rejectUnknown(rejection, ["code", "message", "expectedRevision", "expectedSequence"]);
  requireString(rejection, "code", 128); requireString(rejection, "message", 1_024);
  if (rejection.expectedRevision !== undefined) requireInteger(rejection, "expectedRevision");
  if (rejection.expectedSequence !== undefined) requireInteger(rejection, "expectedSequence");
  return rejection;
}

export function parseWireText(data: string): ClientEnvelope {
  if (Buffer.byteLength(data, "utf8") > MAX_WIRE_BYTES) throw new ProtocolError("message exceeds 256 KiB", "message_too_large");
  let parsed: JsonValue;
  try { parsed = JSON.parse(data) as JsonValue; } catch { throw new ProtocolError("message is not valid JSON"); }
  return parseClientEnvelope(parsed);
}
