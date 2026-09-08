import assert from "node:assert/strict";
import test from "node:test";
import { deflateSync } from "node:zlib";
import { ILLUSTRATION_MODEL, MAX_IMAGE_PROVIDER_PNG_BYTES, MAX_IMAGE_PROVIDER_RESPONSE_BYTES, OpenAIImageProvider } from "../src/illustrations/provider.js";

const image = png();
const request = () => ({ prompt: "Show the selected component's internal flow.", signal: new AbortController().signal });
const imageResponse = (encoded = image.toString("base64")) => Response.json({ data: [{ b64_json: encoded }] });

test("generation sends exact Flare settings and returns the validated PNG", async () => {
  const provider = new OpenAIImageProvider("test-key", async (url, init) => {
    assert.equal(url, "https://api.openai.com/v1/images/generations");
    assert.equal(init?.method, "POST");
    assert.equal(new Headers(init?.headers).get("authorization"), "Bearer test-key");
    assert.equal(new Headers(init?.headers).get("content-type"), "application/json");
    assert.ok(init?.signal instanceof AbortSignal);
    assert.deepEqual(JSON.parse(init?.body as string), { model: "gpt-image-2.5-flare", prompt: request().prompt, n: 1, size: "1024x1024", quality: "medium", output_format: "png" });
    return imageResponse();
  });
  assert.deepEqual(await provider.generate(request()), { bytes: image, model: ILLUSTRATION_MODEL });
});

test("refinement sends the prior PNG as multipart image[] with the same settings", async () => {
  const provider = new OpenAIImageProvider("test-key", async (url, init) => {
    assert.equal(url, "https://api.openai.com/v1/images/edits");
    assert.equal(new Headers(init?.headers).get("content-type"), null);
    assert.ok(init?.body instanceof FormData);
    const form = init.body;
    assert.deepEqual([...form.keys()].sort(), ["image[]", "model", "n", "output_format", "prompt", "quality", "size"]);
    assert.equal(form.get("model"), "gpt-image-2.5-flare");
    assert.equal(form.get("n"), "1");
    assert.equal(form.get("size"), "1024x1024");
    assert.equal(form.get("quality"), "medium");
    assert.equal(form.get("output_format"), "png");
    assert.equal(form.get("prompt"), request().prompt);
    const source = form.get("image[]");
    assert.ok(source instanceof Blob);
    assert.equal(source.type, "image/png");
    assert.deepEqual(Buffer.from(await source.arrayBuffer()), image);
    return imageResponse();
  });
  assert.deepEqual(await provider.generate({ ...request(), source: { bytes: image, mimeType: "image/png" } }), { bytes: image, model: ILLUSTRATION_MODEL });
});

test("pre-cancelled generation never calls the provider", async () => {
  let calls = 0;
  const provider = new OpenAIImageProvider("test-key", async () => { calls += 1; return imageResponse(); });
  const controller = new AbortController();
  controller.abort();
  await assert.rejects(provider.generate({ ...request(), signal: controller.signal }), { name: "AbortError" });
  assert.equal(calls, 0);
});

test("cancellation settles even when fetch ignores its signal", { timeout: 1000 }, async () => {
  let transportSignal: AbortSignal | null | undefined;
  const provider = new OpenAIImageProvider("test-key", (_url, init) => {
    transportSignal = init?.signal;
    return new Promise<Response>(() => {});
  });
  const controller = new AbortController();
  const result = provider.generate({ ...request(), signal: controller.signal });
  controller.abort();
  await assert.rejects(result, { name: "AbortError" });
  assert.equal(transportSignal?.aborted, true);
});

test("deadline settles even when fetch ignores its signal", { timeout: 1000 }, async () => {
  let transportSignal: AbortSignal | null | undefined;
  const provider = new OpenAIImageProvider("test-key", (_url, init) => {
    transportSignal = init?.signal;
    return new Promise<Response>(() => {});
  }, { timeoutMs: 10 });
  await assert.rejects(provider.generate(request()), /timed out/);
  assert.equal(transportSignal?.aborted, true);
});

test("deadline covers a stalled response body and cancels its reader", { timeout: 1000 }, async () => {
  let cancelled = false;
  const provider = new OpenAIImageProvider("test-key", async () => new Response(new ReadableStream({
    start(controller) { controller.enqueue(new TextEncoder().encode('{"data":')); },
    cancel() { cancelled = true; }
  })), { timeoutMs: 10 });
  await assert.rejects(provider.generate(request()), /timed out/);
  assert.equal(cancelled, true);
});

test("late fetch completion after cancellation does not return an image", { timeout: 1000 }, async () => {
  let finish!: (response: Response) => void;
  const provider = new OpenAIImageProvider("test-key", () => new Promise<Response>((resolve) => { finish = resolve; }));
  const controller = new AbortController();
  const result = provider.generate({ ...request(), signal: controller.signal });
  controller.abort();
  await assert.rejects(result, { name: "AbortError" });
  let cancelled = false;
  finish(new Response(new ReadableStream({ cancel() { cancelled = true; } })));
  await new Promise<void>((resolve) => setImmediate(resolve));
  assert.equal(cancelled, true);
});

test("provider failures expose status without provider error content", async () => {
  const provider = new OpenAIImageProvider("test-key", async () => new Response("private prompt and secret", { status: 429 }));
  await assert.rejects(provider.generate(request()), { message: "Image request failed (429)." });
  const disconnected = new OpenAIImageProvider("test-key", async () => { throw new Error("private transport details"); });
  await assert.rejects(disconnected.generate(request()), { message: "Image provider could not be reached." });
  const interrupted = new OpenAIImageProvider("test-key", async () => new Response(new ReadableStream({
    start(controller) { controller.error(new Error("private response details")); }
  })));
  await assert.rejects(interrupted.generate(request()), { message: "Image provider response could not be read." });
});

test("malformed response JSON and missing or multiple image results are rejected", async () => {
  const responses = [new Response("{"), Response.json({ data: [] }), Response.json({ data: [{ url: "https://example.com/image.png" }] }), Response.json({ data: [{ b64_json: image.toString("base64") }, { b64_json: image.toString("base64") }] }), new Response(new Uint8Array([0xff]))];
  for (const response of responses) {
    await assert.rejects(new OpenAIImageProvider("test-key", async () => response).generate(request()), /invalid JSON|no single PNG/);
  }
});

test("strict base64 rejects padding errors, whitespace, invalid symbols and noncanonical bits", async () => {
  for (const encoded of ["", "A", "Zg=", "Zg===", "Zh==", "Zm9=", "Zm9v\n", "Zm9_"]) {
    await assert.rejects(new OpenAIImageProvider("test-key", async () => imageResponse(encoded)).generate(request()), /invalid base64/);
  }
});

test("non-PNG, truncated PNG and oversized PNG dimensions are rejected", async () => {
  for (const bytes of [Buffer.from("not a PNG"), image.subarray(0, 30), png(4097, 1), png(1, 4097), png(0, 1)]) {
    await assert.rejects(new OpenAIImageProvider("test-key", async () => imageResponse(bytes.toString("base64"))).generate(request()));
  }
});

test("refinement validates its source before calling fetch", async () => {
  let calls = 0;
  const provider = new OpenAIImageProvider("test-key", async () => { calls += 1; return imageResponse(); });
  await assert.rejects(provider.generate({ ...request(), source: { bytes: Buffer.from("not a PNG"), mimeType: "image/png" } }));
  assert.equal(calls, 0);
});

test("encoded PNG larger than 12 MiB is rejected before decoding", async () => {
  const encoded = Buffer.alloc(MAX_IMAGE_PROVIDER_PNG_BYTES + 1).toString("base64");
  await assert.rejects(new OpenAIImageProvider("test-key", async () => imageResponse(encoded)).generate(request()), /PNG exceeds the size limit/);
});

test("the response bound permits a valid PNG at the full 12 MiB image limit", async () => {
  const padding = chunk("npAD", Buffer.alloc(MAX_IMAGE_PROVIDER_PNG_BYTES - image.length - 12));
  const largeImage = Buffer.concat([image.subarray(0, 33), padding, image.subarray(33)]);
  assert.equal(largeImage.length, MAX_IMAGE_PROVIDER_PNG_BYTES);
  const provider = new OpenAIImageProvider("test-key", async () => imageResponse(largeImage.toString("base64")));
  assert.deepEqual((await provider.generate(request())).bytes, largeImage);
});

test("response Content-Length is bounded without consuming an oversized body", async () => {
  let cancelled = false;
  const provider = new OpenAIImageProvider("test-key", async () => new Response(new ReadableStream({ cancel() { cancelled = true; } }), {
    headers: { "content-length": String(MAX_IMAGE_PROVIDER_RESPONSE_BYTES + 1) }
  }));
  await assert.rejects(provider.generate(request()), /response exceeds the size limit/);
  assert.equal(cancelled, true);
});

test("stream byte limit catches bodies without a trustworthy Content-Length", async () => {
  let cancelled = false;
  let pulled = 0;
  const chunk = new Uint8Array(1024 * 1024);
  const provider = new OpenAIImageProvider("test-key", async () => new Response(new ReadableStream({
    pull(controller) { pulled += 1; controller.enqueue(chunk); },
    cancel() { cancelled = true; }
  }), { headers: { "content-length": "1" } }));
  await assert.rejects(provider.generate(request()), /response exceeds the size limit/);
  assert.equal(cancelled, true);
  assert.ok(pulled <= 19);
});

test("invalid deadline settings are rejected", () => {
  for (const timeoutMs of [0, -1, NaN, Infinity]) {
    assert.throws(() => new OpenAIImageProvider("test-key", fetch, { timeoutMs }), /positive and finite/);
  }
});

function png(width = 1, height = 1): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(Buffer.from([0, 255, 0, 0, 255]))), chunk("IEND", Buffer.alloc(0))]);
}

function chunk(type: string, payload: Buffer): Buffer {
  const bytes = Buffer.alloc(payload.length + 12);
  bytes.writeUInt32BE(payload.length, 0);
  bytes.write(type, 4, "ascii");
  payload.copy(bytes, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, bytes.length - 4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4);
  return bytes;
}
