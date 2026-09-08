import { appendFileSync, existsSync, mkdirSync, renameSync, statSync } from "node:fs";
import { join } from "node:path";

export type DiagnosticLevel = "debug" | "info" | "warn" | "error";
export interface DiagnosticFields {
  sessionId?: string;
  requestId?: string;
  durationMs?: number;
  status?: number | string;
  bytes?: number;
  reason?: string;
  safeError?: string;
  [key: string]: boolean | number | string | undefined;
}
export interface DiagnosticLogger { log(component: string, event: string, fields?: DiagnosticFields, level?: DiagnosticLevel): void; }

const forbidden = /(?:api[_-]?key|authorization|auth|token|secret|password|prompt|transcript|audio|arguments|content|text|body|payload|input|output|message|raw)/i;
const numericMetrics = new Set(["inputBytes", "inputTokens", "outputTokens", "cachedInputTokens", "cacheWriteTokens", "reasoningTokens"]);
const MAX_FILE_BYTES = 2 * 1024 * 1024;
const MAX_FIELDS = 24;

export class JsonlLogger implements DiagnosticLogger {
  constructor(private readonly directory = process.env.ASTRA_LOG_DIR, private readonly stdout: Pick<Console, "log"> = console) {}
  log(component: string, event: string, fields: DiagnosticFields = {}, level: DiagnosticLevel = "info"): void {
    const safe: Record<string, boolean | number | string> = { timestamp: new Date().toISOString(), component, event, level };
    let fieldCount = 0;
    for (const [key, value] of Object.entries(fields)) {
      const isSafeMetric = numericMetrics.has(key) && typeof value === "number" && Number.isSafeInteger(value) && value >= 0;
      if (fieldCount >= MAX_FIELDS || value === undefined || (forbidden.test(key) && !isSafeMetric)) continue;
      safe[key] = typeof value === "string" ? scrubValue(value) : value;
      fieldCount += 1;
    }
    const line = JSON.stringify(safe);
    this.stdout.log(line);
    if (!this.directory) return;
    try {
      mkdirSync(this.directory, { recursive: true });
      const file = join(this.directory, "astra-session.jsonl");
      if (existsSync(file) && statSync(file).size + Buffer.byteLength(line) + 1 > MAX_FILE_BYTES) renameSync(file, `${file}.1`);
      appendFileSync(file, `${line}\n`, { encoding: "utf8" });
    } catch (error) {
      this.stdout.log(JSON.stringify({ timestamp: new Date().toISOString(), component: "diagnostics", event: "log_write_failed", level: "warn", safeError: safeError(error) }));
    }
  }
}

export function safeError(error: unknown): string {
  // Error messages can contain provider or client payload fragments. Preserve only the
  // stable error class, which is enough to correlate a failure without retaining input.
  return error instanceof Error && error.name ? `${error.name}: request failed` : "unknown_error";
}

function scrubValue(value: string): string {
  return value
    .replace(/Bearer\s+[^\s,]+/gi, "Bearer [redacted]")
    .replace(/\b(?:sk|sess|tok)_[A-Za-z0-9_-]+\b/g, "[redacted]")
    .replace(/\b(?:api[_-]?key|authorization|token|secret|password|client[_-]?secret)\s*[:=]\s*[^\s,}]+/gi, "$1=[redacted]")
    .slice(0, 512);
}
