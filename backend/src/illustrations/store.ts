import { createHash, randomUUID } from "node:crypto";
import { constants } from "node:fs";
import { mkdir, open, readdir, rename, rm, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { inflateSync } from "node:zlib";

export const MAX_ILLUSTRATION_BYTES = 12 * 1024 * 1024;
const MAX_STORE_BYTES = 128 * 1024 * 1024;
const MAX_ARTIFACTS = 64;
const MAX_MANIFEST_BYTES = 32 * 1024;
const MAX_CACHE_KEYS = 256;
const SHA256 = /^[a-f0-9]{64}$/;
const PNG_SIGNATURE = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);

export interface IllustrationArtifact {
  artifactId: string;
  sha256: string;
  mimeType: "image/png";
  width: number;
  height: number;
  byteCount: number;
  model: string;
  sourceRevision: number;
  path: string;
  createdAt: string;
  sourceArtifactId?: string;
}

export interface PutIllustrationArtifact {
  bytes: Buffer;
  model: string;
  sourceRevision: number;
  sourceArtifactId?: string;
  cacheKey: string;
  provenance: Record<string, unknown>;
}

interface ArtifactRecord {
  artifact: IllustrationArtifact;
  diskBytes: number;
}

interface GenerationReceipt extends ArtifactRecord {
  key: string;
  name: string;
}

/** Content-addressed PNGs and separate immutable, bounded generation receipts. */
export class IllustrationArtifactStore {
  readonly directory: string;
  private readonly maxBytes: number;
  private readonly maxArtifacts: number;
  private initialized = false;
  private sequence = Promise.resolve();
  private readonly records = new Map<string, ArtifactRecord>();
  private readonly cache = new Map<string, GenerationReceipt>();

  constructor(options: { directory?: string; maxBytes?: number; maxArtifacts?: number } = {}) {
    this.directory = options.directory ?? fileURLToPath(new URL("../../../.local/illustrations/", import.meta.url));
    this.maxBytes = boundedInteger(options.maxBytes ?? MAX_STORE_BYTES, 1, MAX_STORE_BYTES, "store byte limit");
    this.maxArtifacts = boundedInteger(options.maxArtifacts ?? MAX_ARTIFACTS, 1, MAX_ARTIFACTS, "artifact limit");
  }

  async getArtifact(artifactId: string): Promise<IllustrationArtifact | undefined> {
    return this.serial(async () => {
      if (!await this.readValid(artifactId)) return undefined;
      return { ...this.records.get(artifactId)!.artifact };
    });
  }

  async readArtifact(artifactId: string): Promise<Buffer | undefined> {
    return this.serial(() => this.readValid(artifactId));
  }

  async lookup(cacheKey: string): Promise<IllustrationArtifact | undefined> {
    return this.serial(async () => {
      const receipt = this.cache.get(hashCacheKey(cacheKey));
      if (!receipt || !await this.readValid(receipt.artifact.artifactId)) return undefined;
      return { ...receipt.artifact };
    });
  }

  async put(input: PutIllustrationArtifact): Promise<IllustrationArtifact> {
    // Copy before yielding so a caller cannot change validated bytes during a disk write.
    const bytes = Buffer.from(input.bytes);
    const inspected = inspectIllustrationPNG(bytes);
    const artifact: IllustrationArtifact = {
      artifactId: `sha256:${inspected.sha256}`,
      ...inspected,
      mimeType: "image/png",
      model: input.model,
      sourceRevision: input.sourceRevision,
      path: `/illustrations/artifacts/${inspected.sha256}.png`,
      createdAt: new Date().toISOString(),
      ...(input.sourceArtifactId === undefined ? {} : { sourceArtifactId: input.sourceArtifactId })
    };
    validateArtifact(artifact);
    if (!isRecord(input.provenance)) throw new Error("Invalid illustration provenance");
    const key = hashCacheKey(input.cacheKey);
    const manifest = JSON.stringify({ version: 1, artifact, provenance: input.provenance });
    const receiptContent = JSON.stringify({ version: 1, artifact, provenance: input.provenance, key });
    if (Buffer.byteLength(receiptContent) > MAX_MANIFEST_BYTES) throw new Error("Illustration provenance exceeds the storage limit");
    const diskBytes = bytes.length + Buffer.byteLength(manifest);
    const receipt: GenerationReceipt = { artifact, key, name: `receipt-${createHash("sha256").update(receiptContent).digest("hex")}.json`, diskBytes: Buffer.byteLength(receiptContent) };
    if (diskBytes + receipt.diskBytes > this.maxBytes) throw new Error("Illustration exceeds the storage budget");
    return this.serial(async () => {
      const exists = Boolean(await this.readValid(artifact.artifactId));
      await this.removeReceipt(key);
      await this.enforceBounds((exists ? 0 : diskBytes) + receipt.diskBytes, exists ? 0 : 1, 1, artifact.artifactId);
      if (!exists) {
        await this.atomicWrite(`${artifact.sha256}.png`, bytes);
        try {
          await this.atomicWrite(`${artifact.sha256}.json`, manifest);
        } catch (error) {
          await rm(join(this.directory, `${artifact.sha256}.png`), { force: true });
          throw error;
        }
        this.records.set(artifact.artifactId, { artifact, diskBytes });
      }
      await this.atomicWrite(receipt.name, receiptContent);
      this.cache.set(key, receipt);
      return { ...artifact };
    });
  }

  private serial<T>(operation: () => Promise<T>): Promise<T> {
    const result = this.sequence.then(async () => {
      await this.initialize();
      return operation();
    });
    this.sequence = result.then(() => undefined, () => undefined);
    return result;
  }

  private async initialize(): Promise<void> {
    if (this.initialized) return;
    await mkdir(this.directory, { recursive: true, mode: 0o700 });
    const names = await readdir(this.directory);
    const loaded: ArtifactRecord[] = [];
    for (const name of names) {
      if (/^\.[a-f0-9-]+\.tmp$/.test(name)) await rm(join(this.directory, name), { force: true });
      if (!/^[a-f0-9]{64}\.json$/.test(name)) continue;
      const sha256 = name.slice(0, -5);
      try {
        const manifestBytes = await this.readBounded(name, MAX_MANIFEST_BYTES);
        const manifest: unknown = JSON.parse(manifestBytes.toString("utf8"));
        if (!isRecord(manifest) || manifest.version !== 1 || !isRecord(manifest.provenance)) throw new Error("Invalid illustration manifest");
        const artifact = validateArtifact(manifest.artifact);
        if (artifact.sha256 !== sha256) throw new Error("Illustration manifest identity mismatch");
        const bytes = await this.readBounded(`${sha256}.png`, MAX_ILLUSTRATION_BYTES);
        verifyArtifact(bytes, artifact);
        loaded.push({ artifact, diskBytes: bytes.length + manifestBytes.length });
      } catch {
        await this.removeFiles(sha256);
      }
    }
    loaded.sort((a, b) => a.artifact.createdAt.localeCompare(b.artifact.createdAt));
    this.records.clear();
    for (const record of loaded) this.records.set(record.artifact.artifactId, record);
    for (const name of names) {
      if (/^[a-f0-9]{64}\.png$/.test(name) && !this.records.has(`sha256:${name.slice(0, -4)}`)) await rm(join(this.directory, name), { force: true });
    }
    this.cache.clear();
    const receipts: GenerationReceipt[] = [];
    for (const name of names) {
      if (!/^receipt-[a-f0-9]{64}\.json$/.test(name)) continue;
      try {
        const content = await this.readBounded(name, MAX_MANIFEST_BYTES);
        const value: unknown = JSON.parse(content.toString("utf8"));
        if (name !== `receipt-${createHash("sha256").update(content).digest("hex")}.json` || !isRecord(value) || value.version !== 1 || typeof value.key !== "string" || !SHA256.test(value.key) || !isRecord(value.provenance)) throw new Error("Invalid illustration generation receipt");
        const artifact = validateArtifact(value.artifact);
        const blob = this.records.get(artifact.artifactId)?.artifact;
        if (!blob || blob.sha256 !== artifact.sha256 || blob.byteCount !== artifact.byteCount || blob.width !== artifact.width || blob.height !== artifact.height) throw new Error("Illustration receipt has no matching content");
        receipts.push({ artifact, key: value.key, name, diskBytes: content.length });
      } catch {
        await rm(join(this.directory, name), { force: true });
      }
    }
    receipts.sort((a, b) => a.artifact.createdAt.localeCompare(b.artifact.createdAt));
    for (const receipt of receipts) {
      await this.removeReceipt(receipt.key);
      this.cache.set(receipt.key, receipt);
    }
    await this.enforceBounds(0, 0, 0);
    this.initialized = true;
  }

  private async readValid(artifactId: string): Promise<Buffer | undefined> {
    const record = this.records.get(artifactId);
    if (!record) return undefined;
    try {
      const bytes = await this.readBounded(`${record.artifact.sha256}.png`, MAX_ILLUSTRATION_BYTES);
      verifyArtifact(bytes, record.artifact);
      return bytes;
    } catch {
      await this.remove(artifactId);
      return undefined;
    }
  }

  private async readBounded(name: string, limit: number): Promise<Buffer> {
    const file = await open(join(this.directory, name), constants.O_RDONLY | constants.O_NOFOLLOW);
    try {
      const stat = await file.stat();
      if (!stat.isFile() || stat.size > limit) throw new Error("Invalid illustration file");
      const bytes = Buffer.alloc(stat.size);
      let offset = 0;
      while (offset < bytes.length) {
        const { bytesRead } = await file.read(bytes, offset, bytes.length - offset, offset);
        if (bytesRead === 0) throw new Error("Illustration file was truncated during the read");
        offset += bytesRead;
      }
      if ((await file.read(Buffer.alloc(1), 0, 1, offset)).bytesRead !== 0) throw new Error("Illustration file changed during the read");
      return bytes;
    } finally {
      await file.close();
    }
  }

  private async enforceBounds(incomingBytes: number, incomingCount: number, incomingReceipts: number, protectedArtifactId?: string): Promise<void> {
    const totalBytes = () => [...this.records.values(), ...this.cache.values()].reduce((total, record) => total + record.diskBytes, 0);
    while (this.cache.size + incomingReceipts > MAX_CACHE_KEYS) await this.removeReceipt(this.cache.keys().next().value!);
    while (this.records.size + incomingCount > this.maxArtifacts || totalBytes() + incomingBytes > this.maxBytes) {
      const oldest = [...this.records.entries()].find(([id]) => id !== protectedArtifactId);
      if (!oldest && this.cache.size) {
        await this.removeReceipt(this.cache.keys().next().value!);
        continue;
      }
      if (!oldest) throw new Error("Illustration exceeds the storage budget");
      await this.remove(oldest[0]);
    }
  }

  private async remove(artifactId: string): Promise<void> {
    const record = this.records.get(artifactId);
    if (!record) return;
    await this.removeFiles(record.artifact.sha256);
    this.records.delete(artifactId);
    for (const [key, receipt] of this.cache) if (receipt.artifact.artifactId === artifactId) await this.removeReceipt(key);
  }

  private async removeReceipt(key: string): Promise<void> {
    const receipt = this.cache.get(key);
    if (!receipt) return;
    await rm(join(this.directory, receipt.name), { force: true });
    this.cache.delete(key);
  }

  private async removeFiles(sha256: string): Promise<void> {
    await rm(join(this.directory, `${sha256}.json`), { force: true });
    await rm(join(this.directory, `${sha256}.png`), { force: true });
  }

  private async atomicWrite(name: string, content: Buffer | string): Promise<void> {
    const temporary = join(this.directory, `.${randomUUID()}.tmp`);
    try {
      await writeFile(temporary, content, { mode: 0o600, flag: "wx", flush: true });
      await rename(temporary, join(this.directory, name));
    } finally {
      await rm(temporary, { force: true });
    }
  }
}

function verifyArtifact(bytes: Buffer, artifact: IllustrationArtifact): void {
  const inspected = inspectIllustrationPNG(bytes);
  if (inspected.sha256 !== artifact.sha256 || inspected.width !== artifact.width || inspected.height !== artifact.height || inspected.byteCount !== artifact.byteCount) throw new Error("Illustration checksum or dimensions mismatch");
}

function validateArtifact(value: unknown): IllustrationArtifact {
  if (!isRecord(value) || typeof value.sha256 !== "string" || !SHA256.test(value.sha256) || value.artifactId !== `sha256:${value.sha256}` || value.path !== `/illustrations/artifacts/${value.sha256}.png` || value.mimeType !== "image/png") throw new Error("Invalid illustration artifact identity");
  boundedInteger(value.width, 1, 2048, "image width");
  boundedInteger(value.height, 1, 2048, "image height");
  boundedInteger(value.byteCount, 1, MAX_ILLUSTRATION_BYTES, "image size");
  boundedInteger(value.sourceRevision, 0, Number.MAX_SAFE_INTEGER, "source revision");
  if (typeof value.model !== "string" || value.model.length === 0 || Buffer.byteLength(value.model) > 128 || typeof value.createdAt !== "string" || !Number.isFinite(Date.parse(value.createdAt))) throw new Error("Invalid illustration artifact metadata");
  if (value.sourceArtifactId !== undefined && (typeof value.sourceArtifactId !== "string" || !/^sha256:[a-f0-9]{64}$/.test(value.sourceArtifactId))) throw new Error("Invalid source illustration identity");
  return {
    artifactId: value.artifactId as string, sha256: value.sha256, mimeType: "image/png",
    width: value.width as number, height: value.height as number, byteCount: value.byteCount as number,
    model: value.model, sourceRevision: value.sourceRevision as number, path: value.path as string,
    createdAt: value.createdAt,
    ...(value.sourceArtifactId === undefined ? {} : { sourceArtifactId: value.sourceArtifactId as string })
  };
}

function hashCacheKey(key: string): string {
  if (typeof key !== "string" || key.length === 0 || Buffer.byteLength(key) > 64 * 1024) throw new Error("Invalid illustration cache key");
  return createHash("sha256").update(key).digest("hex");
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return value !== null && typeof value === "object" && !Array.isArray(value);
}

function boundedInteger(value: unknown, minimum: number, maximum: number, description: string): number {
  if (typeof value !== "number" || !Number.isSafeInteger(value) || value < minimum || value > maximum) throw new Error(`Invalid illustration ${description}`);
  return value;
}

const CRC_TABLE = new Uint32Array(256).map((_, index) => {
  let crc = index;
  for (let bit = 0; bit < 8; bit++) crc = crc & 1 ? 0xedb88320 ^ (crc >>> 1) : crc >>> 1;
  return crc >>> 0;
});

function crc32(bytes: Buffer): number {
  let crc = 0xffffffff;
  for (const byte of bytes) crc = CRC_TABLE[(crc ^ byte) & 255]! ^ (crc >>> 8);
  return (crc ^ 0xffffffff) >>> 0;
}

/** Validate a complete, bounded PNG, including chunk checksums and decoded scanlines. */
export function inspectIllustrationPNG(bytes: Buffer): { width: number; height: number; byteCount: number; sha256: string } {
  if (bytes.length > MAX_ILLUSTRATION_BYTES || bytes.length < 45 || !bytes.subarray(0, 8).equals(PNG_SIGNATURE)) throw new Error("Invalid illustration PNG");
  let offset = 8;
  let width = 0;
  let height = 0;
  let bitsPerPixel = 0;
  let colorType = -1;
  let interlaced = false;
  let palette = false;
  let ended = false;
  let dataEnded = false;
  const data: Buffer[] = [];
  while (offset < bytes.length) {
    if (bytes.length - offset < 12) throw new Error("Truncated illustration PNG");
    const length = bytes.readUInt32BE(offset);
    const end = offset + length + 12;
    if (end > bytes.length) throw new Error("Truncated illustration PNG chunk");
    const type = bytes.toString("ascii", offset + 4, offset + 8);
    const chunk = bytes.subarray(offset + 8, end - 4);
    if (!/^[A-Za-z]{4}$/.test(type) || crc32(bytes.subarray(offset + 4, end - 4)) !== bytes.readUInt32BE(end - 4)) throw new Error("Invalid illustration PNG chunk checksum");
    if (offset === 8 && type !== "IHDR") throw new Error("Missing illustration PNG header");
    if (type === "IHDR") {
      if (offset !== 8 || length !== 13) throw new Error("Invalid illustration PNG header");
      width = boundedInteger(chunk.readUInt32BE(0), 1, 2048, "PNG width");
      height = boundedInteger(chunk.readUInt32BE(4), 1, 2048, "PNG height");
      const depth = chunk[8]!;
      colorType = chunk[9]!;
      const depths: Record<number, number[]> = { 0: [1, 2, 4, 8, 16], 2: [8, 16], 3: [1, 2, 4, 8], 4: [8, 16], 6: [8, 16] };
      const channels: Record<number, number> = { 0: 1, 2: 3, 3: 1, 4: 2, 6: 4 };
      if (!depths[colorType]?.includes(depth) || chunk[10] !== 0 || chunk[11] !== 0 || chunk[12]! > 1) throw new Error("Unsupported illustration PNG format");
      bitsPerPixel = channels[colorType]! * depth;
      interlaced = chunk[12] === 1;
    } else if (type === "PLTE") {
      if (palette || data.length || length === 0 || length > 768 || length % 3 !== 0 || colorType === 0 || colorType === 4) throw new Error("Invalid illustration PNG palette");
      palette = true;
    } else if (type === "IDAT") {
      if (dataEnded || (colorType === 3 && !palette)) throw new Error("Invalid illustration PNG image data order");
      data.push(chunk);
    } else if (type === "IEND") {
      if (length !== 0 || data.length === 0 || end !== bytes.length) throw new Error("Invalid illustration PNG end");
      ended = true;
    } else if (type[0] === type[0]!.toUpperCase()) {
      throw new Error("Unsupported critical illustration PNG chunk");
    }
    if (data.length && type !== "IDAT") dataEnded = true;
    offset = end;
  }
  if (!ended) throw new Error("Incomplete illustration PNG");
  const passes = interlaced ? [[0, 0, 8, 8], [4, 0, 8, 8], [0, 4, 4, 8], [2, 0, 4, 4], [0, 2, 2, 4], [1, 0, 2, 2], [0, 1, 1, 2]] : [[0, 0, 1, 1]];
  const scanlines = passes.map(([x, y, dx, dy]) => {
    const columns = Math.max(0, Math.ceil((width - x!) / dx!));
    const rows = columns ? Math.max(0, Math.ceil((height - y!) / dy!)) : 0;
    return { rows, rowBytes: 1 + Math.ceil(columns * bitsPerPixel / 8) };
  });
  const decodedSize = scanlines.reduce((total, pass) => total + pass.rows * pass.rowBytes, 0);
  let decoded: Buffer;
  try { decoded = inflateSync(Buffer.concat(data), { maxOutputLength: decodedSize }); }
  catch { throw new Error("Invalid illustration PNG compressed data"); }
  if (decoded.length !== decodedSize) throw new Error("Invalid illustration PNG scanline size");
  let rowOffset = 0;
  for (const pass of scanlines) for (let row = 0; row < pass.rows; row++) {
    if (decoded[rowOffset]! > 4) throw new Error("Invalid illustration PNG scanline filter");
    rowOffset += pass.rowBytes;
  }
  return { width, height, byteCount: bytes.length, sha256: createHash("sha256").update(bytes).digest("hex") };
}
