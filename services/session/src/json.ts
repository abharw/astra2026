export type JsonPrimitive = string | number | boolean | null;
export type JsonValue = JsonPrimitive | JsonObject | JsonValue[];
export interface JsonObject { [key: string]: JsonValue }

export function isObject(value: unknown): value is JsonObject {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isString(value: unknown): value is string {
  return typeof value === "string";
}

export function isNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}

export function asObject(value: unknown, label: string): JsonObject {
  if (!isObject(value)) throw new ProtocolError(`${label} must be an object`);
  return value;
}

export class ProtocolError extends Error {
  constructor(message: string, readonly code = "invalid_message") {
    super(message);
    this.name = "ProtocolError";
  }
}

export function requireString(object: JsonObject, key: string, max = 8_192): string {
  const value = object[key];
  if (!isString(value) || value.length === 0 || value.length > max) {
    throw new ProtocolError(`${key} must be a non-empty string up to ${max} characters`);
  }
  return value;
}

export function requireInteger(object: JsonObject, key: string): number {
  const value = object[key];
  if (!isNumber(value) || !Number.isSafeInteger(value) || value < 0) {
    throw new ProtocolError(`${key} must be a non-negative safe integer`);
  }
  return value;
}

export function requireArray(object: JsonObject, key: string, max = 2_000): JsonValue[] {
  const value = object[key];
  if (!Array.isArray(value) || value.length > max) {
    throw new ProtocolError(`${key} must be an array with at most ${max} entries`);
  }
  return value;
}

export function rejectUnknown(object: JsonObject, allowed: readonly string[]): void {
  const allowedSet = new Set(allowed);
  for (const key of Object.keys(object)) if (!allowedSet.has(key)) throw new ProtocolError(`unknown property: ${key}`, "unknown_property");
}
