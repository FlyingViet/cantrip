import { deflateSync } from "node:zlib";

/** Synthetic solid-color pixels generated here, never personal artwork. */
export function syntheticPNG(width = 1, height = width): string {
  function chunk(type: string, bytes: Buffer): Buffer {
    const body = Buffer.concat([Buffer.from(type), bytes]);
    let crc = 0xffffffff;
    for (const byte of body) {
      crc ^= byte;
      for (let bit = 0; bit < 8; bit++) crc = (crc >>> 1) ^ ((crc & 1) ? 0xedb88320 : 0);
    }
    const length = Buffer.alloc(4), checksum = Buffer.alloc(4);
    length.writeUInt32BE(bytes.length); checksum.writeUInt32BE((crc ^ 0xffffffff) >>> 0);
    return Buffer.concat([length, body, checksum]);
  }
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width); header.writeUInt32BE(height, 4); header[8] = 8; header[9] = 6;
  const pixels = Buffer.alloc((width * 4 + 1) * height);
  for (let row = 0; row < height; row++) {
    for (let col = 0; col < width; col++) pixels.set([130, 90, 180, 255], row * (width * 4 + 1) + 1 + col * 4);
  }
  return Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]), chunk("IHDR", header),
    chunk("IDAT", deflateSync(pixels)), chunk("IEND", Buffer.alloc(0)),
  ]).toString("base64");
}

export const revisionA = "a".repeat(64), revisionB = "b".repeat(64);
export const syntheticPack = (revision = revisionA) => ({
  version: 1, revision, portrait: syntheticPNG(), blink: syntheticPNG(), sparkX: 0.25, sparkY: 0.75,
});

export function deferred<T>() {
  let resolve!: (value: T) => void, reject!: (error: unknown) => void;
  const promise = new Promise<T>((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

export async function settle(): Promise<void> {
  for (let index = 0; index < 12; index++) await Promise.resolve();
}
