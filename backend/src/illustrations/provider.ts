import { isObject } from "../json.js";
import { MAX_ILLUSTRATION_BYTES, inspectIllustrationPNG } from "./store.js";

export const ILLUSTRATION_MODEL = "gpt-image-2.5-flare";
export const MAX_IMAGE_PROVIDER_RESPONSE_BYTES = 17 * 1024 * 1024;
export const MAX_IMAGE_PROVIDER_PNG_BYTES = MAX_ILLUSTRATION_BYTES;
export const MAX_IMAGE_PROVIDER_TIMEOUT_MS = 150_000;

export interface IllustrationProvider {
  generate(request: {
    prompt: string;
    source?: { bytes: Buffer; mimeType: "image/png" };
    signal: AbortSignal;
  }): Promise<{ bytes: Buffer; model: string }>;
}

type IllustrationRequest = Parameters<IllustrationProvider["generate"]>[0];

/** The Image API adapter owns its deadline; scene authoring has a separate lifetime. */
export class OpenAIImageProvider implements IllustrationProvider {
  private readonly timeoutMs: number;

  constructor(
    private readonly apiKey: string,
    private readonly fetchImpl: typeof fetch = fetch,
    options: { timeoutMs?: number } = {}
  ) {
    const timeoutMs = options.timeoutMs ?? MAX_IMAGE_PROVIDER_TIMEOUT_MS;
    if (!Number.isFinite(timeoutMs) || timeoutMs <= 0) throw new RangeError("Image provider timeout must be positive and finite.");
    this.timeoutMs = Math.min(timeoutMs, MAX_IMAGE_PROVIDER_TIMEOUT_MS);
  }

  async generate(request: IllustrationRequest): Promise<{ bytes: Buffer; model: string }> {
    if (request.signal.aborted) throw cancellationError();
    const controller = new AbortController();
    let interrupt!: (error: Error) => void;
    const interruption = new Promise<never>((_resolve, reject) => {
      interrupt = (error) => {
        controller.abort(error);
        reject(error);
      };
    });
    const onAbort = () => interrupt(cancellationError());
    request.signal.addEventListener("abort", onAbort, { once: true });
    const timer = setTimeout(() => interrupt(new Error("Image generation timed out.")), this.timeoutMs);
    try {
      // Racing the whole operation also settles injected transports that ignore abort.
      return await Promise.race([this.performRequest(request, controller.signal), interruption]);
    } finally {
      clearTimeout(timer);
      request.signal.removeEventListener("abort", onAbort);
    }
  }

  private async performRequest(request: IllustrationRequest, signal: AbortSignal): Promise<{ bytes: Buffer; model: string }> {
    const settings = { model: ILLUSTRATION_MODEL, prompt: request.prompt, n: 1, size: "1024x1024", quality: "medium", output_format: "png" };
    const headers: Record<string, string> = { authorization: `Bearer ${this.apiKey}`, accept: "application/json" };
    let body: BodyInit;
    let endpoint: string;
    if (request.source) {
      if (request.source.mimeType !== "image/png") throw new Error("Illustration refinement requires a PNG source.");
      validatePNG(request.source.bytes);
      const form = new FormData();
      for (const [key, value] of Object.entries(settings)) form.set(key, String(value));
      form.set("image[]", new Blob([new Uint8Array(request.source.bytes)], { type: "image/png" }), "source.png");
      body = form;
      endpoint = "edits";
    } else {
      headers["content-type"] = "application/json";
      body = JSON.stringify(settings);
      endpoint = "generations";
    }
    let response: Response;
    try {
      response = await this.fetchImpl(`https://api.openai.com/v1/images/${endpoint}`, { method: "POST", headers, body, signal });
    } catch {
      signal.throwIfAborted();
      throw new Error("Image provider could not be reached.");
    }
    if (signal.aborted) {
      void response.body?.cancel().catch(() => {});
      signal.throwIfAborted();
    }
    if (!response.ok) {
      // Provider bodies can contain prompt text. Do not retain or surface them.
      void response.body?.cancel().catch(() => {});
      throw new Error(`Image request failed (${response.status}).`);
    }
    const raw = await readBoundedJSON(response, signal);
    signal.throwIfAborted();
    if (!isObject(raw) || !Array.isArray(raw.data) || raw.data.length !== 1 || !isObject(raw.data[0]) || typeof raw.data[0].b64_json !== "string") {
      throw new Error("Image provider returned no single PNG image.");
    }
    const bytes = decodeImage(raw.data[0].b64_json);
    validatePNG(bytes);
    signal.throwIfAborted();
    return { bytes, model: ILLUSTRATION_MODEL };
  }
}

function cancellationError(): DOMException {
  return new DOMException("Image generation cancelled.", "AbortError");
}

function validatePNG(bytes: Buffer): void {
  if (bytes.byteLength > MAX_IMAGE_PROVIDER_PNG_BYTES) throw new Error("Image provider PNG exceeds the size limit.");
  inspectIllustrationPNG(bytes);
}

function decodeImage(encoded: string): Buffer {
  if (encoded.length > Math.ceil(MAX_IMAGE_PROVIDER_PNG_BYTES / 3) * 4) throw new Error("Image provider PNG exceeds the size limit.");
  // Buffer.from accepts malformed and noncanonical base64; reject it explicitly.
  if (encoded.length === 0 || encoded.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(encoded)) {
    throw new Error("Image provider returned invalid base64.");
  }
  const bytes = Buffer.from(encoded, "base64");
  if (bytes.toString("base64") !== encoded) throw new Error("Image provider returned invalid base64.");
  return bytes;
}

async function readBoundedJSON(response: Response, signal: AbortSignal): Promise<unknown> {
  const declaredLength = response.headers.get("content-length");
  if (declaredLength !== null && /^\d+$/.test(declaredLength) && Number(declaredLength) > MAX_IMAGE_PROVIDER_RESPONSE_BYTES) {
    void response.body?.cancel().catch(() => {});
    throw new Error("Image provider response exceeds the size limit.");
  }
  if (!response.body) throw new Error("Image provider returned an empty response.");
  const reader = response.body.getReader();
  const cancel = () => { void reader.cancel().catch(() => {}); };
  signal.addEventListener("abort", cancel, { once: true });
  const chunks: Uint8Array[] = [];
  let byteCount = 0;
  try {
    while (true) {
      signal.throwIfAborted();
      let result: ReadableStreamReadResult<Uint8Array>;
      try {
        result = await reader.read();
      } catch {
        signal.throwIfAborted();
        throw new Error("Image provider response could not be read.");
      }
      const { done, value } = result;
      signal.throwIfAborted();
      if (done) break;
      byteCount += value.byteLength;
      if (byteCount > MAX_IMAGE_PROVIDER_RESPONSE_BYTES) {
        cancel();
        throw new Error("Image provider response exceeds the size limit.");
      }
      chunks.push(value);
    }
  } catch (error) {
    cancel();
    throw error;
  } finally {
    signal.removeEventListener("abort", cancel);
    reader.releaseLock();
  }
  try {
    return JSON.parse(new TextDecoder("utf-8", { fatal: true }).decode(Buffer.concat(chunks, byteCount)));
  } catch {
    throw new Error("Image provider returned invalid JSON.");
  }
}
