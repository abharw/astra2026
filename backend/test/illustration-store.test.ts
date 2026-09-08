import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { mkdtemp, readFile, readdir, rm, stat, symlink, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import test from "node:test";
import { deflateSync } from "node:zlib";
import { IllustrationArtifactStore, MAX_ILLUSTRATION_BYTES, inspectIllustrationPNG } from "../src/illustrations/store.js";

const input = (color = 0, cacheKey = `scene-${color}`) => ({ bytes: png(color), model: "gpt-image-2.5-flare", sourceRevision: 3, cacheKey, provenance: { sceneId: "optical-bench", requestId: `request-${color}` } });

async function directory(t: { after: (action: () => Promise<void>) => void }): Promise<string> {
  const path = await mkdtemp(join(tmpdir(), "astra-illustration-store-"));
  t.after(() => rm(path, { recursive: true, force: true }));
  return path;
}

test("PNG integrity includes chunk checksums, dimensions and decoded scanline validation", () => {
  const bytes = png();
  assert.deepEqual(inspectIllustrationPNG(bytes), { width: 1, height: 1, byteCount: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") });
  const brokenCRC = Buffer.from(bytes);
  brokenCRC[20] = brokenCRC[20]! ^ 1;
  assert.throws(() => inspectIllustrationPNG(brokenCRC), /checksum/);
  assert.throws(() => inspectIllustrationPNG(bytes.subarray(0, -1)), /Truncated/);
  assert.throws(() => inspectIllustrationPNG(Buffer.concat([bytes, Buffer.alloc(1)])), /end/);
  assert.throws(() => inspectIllustrationPNG(png(0, 2049)), /width/);
  assert.throws(() => inspectIllustrationPNG(png(0, 1, Buffer.from([5, 0, 0, 0, 255]))), /filter/);
  assert.throws(() => inspectIllustrationPNG(png(0, 1, Buffer.alloc(100_000))), /compressed data/);
  assert.throws(() => inspectIllustrationPNG(Buffer.alloc(MAX_ILLUSTRATION_BYTES + 1)), /PNG/);
});

test("artifacts persist with immutable provenance, private files and restartable cache lookup", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  const data = input();
  const artifact = await store.put(data);
  assert.equal(artifact.artifactId, `sha256:${artifact.sha256}`);
  assert.equal(artifact.path, `/illustrations/artifacts/${artifact.sha256}.png`);
  assert.equal(artifact.mimeType, "image/png");
  assert.equal(artifact.sourceRevision, 3);
  assert.equal(artifact.byteCount, data.bytes.length);
  assert.deepEqual(await store.getArtifact(artifact.artifactId), artifact);
  assert.deepEqual(await store.readArtifact(artifact.artifactId), data.bytes);
  assert.deepEqual(await store.lookup(data.cacheKey), artifact);
  const manifestPath = join(path, `${artifact.sha256}.json`);
  assert.deepEqual(JSON.parse(await readFile(manifestPath, "utf8")).provenance, data.provenance);
  assert.equal((await stat(manifestPath)).mode & 0o777, 0o600);
  const restarted = new IllustrationArtifactStore({ directory: path });
  assert.deepEqual(await restarted.lookup(data.cacheKey), artifact);
  assert.deepEqual(await restarted.readArtifact(artifact.artifactId), data.bytes);
  assert.equal(await restarted.getArtifact("../../private"), undefined);
  assert.equal(await restarted.lookup("unknown"), undefined);
  const receiptName = (await readdir(path)).find((name) => name.startsWith("receipt-"))!;
  assert.doesNotMatch(await readFile(join(path, receiptName), "utf8"), /scene-0/);
});

test("duplicate image bytes preserve immutable content and distinct generation provenance", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  const original = await store.put(input());
  const manifest = await readFile(join(path, `${original.sha256}.json`), "utf8");
  const repeated = await store.put({ ...input(0, "different-scene"), sourceRevision: 44, sourceArtifactId: original.artifactId, provenance: { requestId: "different-generation" } });
  assert.equal(repeated.artifactId, original.artifactId);
  assert.equal(repeated.sourceRevision, 44);
  assert.equal(repeated.sourceArtifactId, original.artifactId);
  assert.equal(await readFile(join(path, `${original.sha256}.json`), "utf8"), manifest);
  const restarted = new IllustrationArtifactStore({ directory: path });
  assert.deepEqual(await restarted.lookup("different-scene"), repeated);
  assert.deepEqual(await restarted.lookup("scene-0"), original);
  assert.deepEqual(await restarted.getArtifact(original.artifactId), original);
  const receipts = await Promise.all((await readdir(path)).filter((name) => name.startsWith("receipt-")).map(async (name) => JSON.parse(await readFile(join(path, name), "utf8"))));
  assert.deepEqual(receipts.map((receipt) => receipt.artifact.sourceRevision).sort((a, b) => a - b), [3, 44]);
  assert.equal((await readdir(path)).filter((name) => name.endsWith(".png")).length, 1);
});

test("count eviction removes image, receipt and cache aliases while an already-read image stays usable", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path, maxArtifacts: 2 });
  const first = await store.put(input(1));
  const sourceBytes = await store.readArtifact(first.artifactId);
  const [second, third] = await Promise.all([store.put(input(2)), store.put(input(3))]);
  assert.equal(await store.readArtifact(first.artifactId), undefined);
  assert.equal(await store.lookup("scene-1"), undefined);
  assert.deepEqual(sourceBytes, input(1).bytes);
  assert.ok(await store.readArtifact(second.artifactId));
  assert.ok(await store.readArtifact(third.artifactId));
  const names = await readdir(path);
  assert.deepEqual(names.filter((name) => !name.startsWith("receipt-")).sort(), [`${second.sha256}.png`, `${second.sha256}.json`, `${third.sha256}.png`, `${third.sha256}.json`].sort());
  assert.equal(names.filter((name) => name.startsWith("receipt-")).length, 2);
});

test("byte budget includes immutable receipts and rejects oversized puts without displacing existing content", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path, maxBytes: 1800 });
  const first = await store.put(input(1));
  const second = await store.put(input(2));
  assert.equal(await store.getArtifact(first.artifactId), undefined);
  assert.ok(await store.getArtifact(second.artifactId));
  await assert.rejects(store.put({ ...input(3), provenance: { large: "x".repeat(2000) } }), /budget/);
  assert.ok(await store.getArtifact(second.artifactId));
  const names = await readdir(path);
  const artifactBytes = (await Promise.all(names.map(async (name) => (await stat(join(path, name))).size))).reduce((a, b) => a + b, 0);
  assert.ok(artifactBytes <= 1800);
});

test("tampered image data fails closed and removes its cached artifact", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  const artifact = await store.put(input(1));
  await writeFile(join(path, `${artifact.sha256}.png`), png(2));
  assert.equal(await store.lookup("scene-1"), undefined);
  assert.equal(await store.getArtifact(artifact.artifactId), undefined);
  assert.deepEqual(await readdir(path), []);
});

test("restart drops corrupt receipts, orphaned images and interrupted writes", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  const bad = await store.put(input(1));
  const good = await store.put(input(2));
  await writeFile(join(path, `${bad.sha256}.json`), "not-json");
  const orphan = inspectIllustrationPNG(png(3));
  await writeFile(join(path, `${orphan.sha256}.png`), png(3));
  await writeFile(join(path, ".12345678-1234-1234-1234-123456789012.tmp"), "partial");
  await writeFile(join(path, `receipt-${"a".repeat(64)}.json`), "incomplete-receipt");
  const restarted = new IllustrationArtifactStore({ directory: path });
  assert.equal(await restarted.getArtifact(bad.artifactId), undefined);
  assert.deepEqual(await restarted.getArtifact(good.artifactId), good);
  const names = await readdir(path);
  assert.deepEqual(names.filter((name) => !name.startsWith("receipt-")).sort(), [`${good.sha256}.png`, `${good.sha256}.json`].sort());
  assert.equal(names.filter((name) => name.startsWith("receipt-")).length, 1);
});

test("artifact reads do not follow symlinks", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  const artifact = await store.put(input());
  const external = join(path, "unrelated.png");
  await writeFile(external, png());
  const imagePath = join(path, `${artifact.sha256}.png`);
  await rm(imagePath);
  await symlink(external, imagePath);
  assert.equal(await store.readArtifact(artifact.artifactId), undefined);
  assert.deepEqual(await readFile(external), png());
});

test("put snapshots input bytes and returned metadata cannot mutate the store", async (t) => {
  const store = new IllustrationArtifactStore({ directory: await directory(t) });
  const data = input();
  const promise = store.put(data);
  data.bytes.fill(0);
  const artifact = await promise;
  const id = artifact.artifactId;
  artifact.width = 777;
  assert.equal((await store.getArtifact(id))?.width, 1);
  assert.deepEqual(await store.readArtifact(id), png());
});

test("invalid metadata, provenance and limits are rejected before writing artifacts", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  await assert.rejects(store.put({ ...input(), sourceRevision: -1 }), /revision/);
  await assert.rejects(store.put({ ...input(), sourceArtifactId: "../../other" }), /identity/);
  await assert.rejects(store.put({ ...input(), provenance: { huge: "x".repeat(33_000) } }), /provenance/);
  assert.throws(() => new IllustrationArtifactStore({ maxArtifacts: 65 }), /limit/);
  assert.throws(() => new IllustrationArtifactStore({ maxBytes: 129 * 1024 * 1024 }), /limit/);
  assert.deepEqual(await readdir(path), []);
});

test("repeated content has a bounded receipt count with matching cache eviction across restart", async (t) => {
  const path = await directory(t);
  const store = new IllustrationArtifactStore({ directory: path });
  for (let revision = 0; revision < 260; revision++) {
    await store.put({ ...input(0, `revision-${revision}`), sourceRevision: revision });
  }
  const names = await readdir(path);
  assert.equal(names.filter((name) => name.endsWith(".png")).length, 1);
  assert.equal(names.filter((name) => name.startsWith("receipt-")).length, 256);
  assert.equal(await store.lookup("revision-0"), undefined);
  assert.equal((await store.lookup("revision-259"))?.sourceRevision, 259);
  const restarted = new IllustrationArtifactStore({ directory: path });
  assert.equal(await restarted.lookup("revision-0"), undefined);
  assert.equal((await restarted.lookup("revision-259"))?.sourceRevision, 259);
});

function png(color = 0, width = 1, raw = Buffer.from([0, color, 0, 0, 255])): Buffer {
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width, 0);
  header.writeUInt32BE(1, 4);
  header[8] = 8;
  header[9] = 6;
  return Buffer.concat([Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header), chunk("IDAT", deflateSync(raw)), chunk("IEND", Buffer.alloc(0))]);
}

function chunk(type: string, data: Buffer): Buffer {
  const bytes = Buffer.alloc(data.length + 12);
  bytes.writeUInt32BE(data.length, 0);
  bytes.write(type, 4, 4, "ascii");
  data.copy(bytes, 8);
  let crc = 0xffffffff;
  for (const byte of bytes.subarray(4, -4)) {
    crc ^= byte;
    for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  }
  bytes.writeUInt32BE((crc ^ 0xffffffff) >>> 0, bytes.length - 4);
  return bytes;
}
