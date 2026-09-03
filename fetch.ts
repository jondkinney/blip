#!/usr/bin/env bun
/**
 * Blip attachment fetcher — pulls one attachment's bytes from the Mac into
 * the local media cache and prints {ok, path, url} JSON for QML.
 *
 *   bun fetch.ts <attachment-id> <name> <mime>
 *
 * The cache DELIBERATELY relaxes the "no message content on disk" invariant,
 * scoped to media (Fred's call, 2026-08-31): the disk is LUKS-encrypted at
 * rest, so plain files under ~/.cache/blip/att (dir 0700, files 0600) are
 * acceptable. state.json still never holds content.
 *
 * Cache key = <id>-<transform>-<sanitized name>: the transform distinguishes
 * a sips-converted JPEG from the original so the two never collide. LRU by
 * mtime (touched on every hit — atime is unreliable under relatime), capped
 * at 500 MB, evicted after each write.
 */

import { homedir } from "node:os";
import { spawnSync } from "node:child_process";
import {
  closeSync,
  constants,
  fstatSync,
  fsyncSync,
  mkdirSync,
  openSync,
  readSync,
  readdirSync,
  renameSync,
  lstatSync,
  statSync,
  unlinkSync,
  utimesSync,
  writeSync,
} from "node:fs";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const HOME = process.env.HOME ?? homedir();
export const CACHE_DIR = join(process.env.XDG_CACHE_HOME ?? join(HOME, ".cache"), "blip", "att");
export const CACHE_CAP_BYTES = 500 * 1024 * 1024;
export const FETCH_MAX_BYTES = 100 * 1024 * 1024;
const IMAGE_HEADER_BYTES = 64 * 1024;

/** HEIC needs converting on the Mac (sips) — Linux has no decoder. */
export function wantsJpeg(mime: string): boolean {
  return mime === "image/heic" || mime === "image/heif";
}

export function sanitizeName(name: string): string {
  const base = (name || "file").replace(/[^A-Za-z0-9._-]/g, "_").slice(0, 100);
  return base.replace(/^[._]+/, "") || "file";
}

export function cacheFileName(id: string, name: string, mime: string): string {
  const transform = wantsJpeg(mime) ? "jpg" : "orig";
  let file = `${id}-${transform}-${sanitizeName(name)}`;
  if (transform === "jpg" && !/\.jpe?g$/i.test(file)) file += ".jpg";
  return file;
}

/** Oldest-mtime files to delete so the cache fits the cap. Pure for tests. */
export function lruEvictions(
  entries: { name: string; bytes: number; mtimeMs: number }[],
  cap: number,
  keep: string,
): string[] {
  let total = entries.reduce((s, e) => s + e.bytes, 0);
  const out: string[] = [];
  for (const e of [...entries].sort((a, b) => a.mtimeMs - b.mtimeMs)) {
    if (total <= cap) break;
    if (e.name === keep) continue;
    out.push(e.name);
    total -= e.bytes;
  }
  return out;
}

export interface ImageMetrics {
  pixelWidth: number;
  pixelHeight: number;
  pixelRatio: number;
}

const EMPTY_IMAGE_METRICS: ImageMetrics = { pixelWidth: 0, pixelHeight: 0, pixelRatio: 1 };

function densityRatio(xDpi: number, yDpi: number): number {
  if (!Number.isFinite(xDpi) || !Number.isFinite(yDpi) || xDpi <= 0 || yDpi <= 0)
    return 1;
  if (Math.abs(xDpi - yDpi) / Math.max(xDpi, yDpi) > 0.05) return 1;
  const ratio = (xDpi + yDpi) / 144;
  const common = [1, 1.25, 1.5, 1.75, 2, 2.5, 3, 4];
  return common.find((value) => Math.abs(value - ratio) <= 0.06) ?? 1;
}

/** Bounded image metadata used only for display sizing; malformed data falls back to 1×. */
export function imageMetrics(bytes: Buffer, mime: string): ImageMetrics {
  if (!String(mime || "").startsWith("image/") || !bytes || bytes.length < 10)
    return { ...EMPTY_IMAGE_METRICS };

  const png = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (bytes.length >= 24 && bytes.subarray(0, 8).equals(png)) {
    const pixelWidth = bytes.readUInt32BE(16);
    const pixelHeight = bytes.readUInt32BE(20);
    let pixelRatio = 1;
    for (let pos = 8; pos + 12 <= bytes.length;) {
      const length = bytes.readUInt32BE(pos);
      if (length > IMAGE_HEADER_BYTES || pos + 12 + length > bytes.length) break;
      const type = bytes.toString("ascii", pos + 4, pos + 8);
      if (type === "pHYs" && length === 9 && bytes[pos + 16] === 1) {
        const xDpi = bytes.readUInt32BE(pos + 8) * 0.0254;
        const yDpi = bytes.readUInt32BE(pos + 12) * 0.0254;
        pixelRatio = densityRatio(xDpi, yDpi);
        break;
      }
      if (type === "IDAT" || type === "IEND") break;
      pos += 12 + length;
    }
    return { pixelWidth, pixelHeight, pixelRatio };
  }

  if (bytes[0] === 0xff && bytes[1] === 0xd8) {
    let pixelWidth = 0;
    let pixelHeight = 0;
    let pixelRatio = 1;
    const sof = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
    for (let pos = 2; pos + 4 <= bytes.length;) {
      if (bytes[pos] !== 0xff) { pos++; continue; }
      while (pos < bytes.length && bytes[pos] === 0xff) pos++;
      if (pos >= bytes.length) break;
      const marker = bytes[pos++];
      if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
      if (marker === 0xd9 || marker === 0xda || pos + 2 > bytes.length) break;
      const length = bytes.readUInt16BE(pos);
      if (length < 2 || pos + length > bytes.length) break;
      const data = pos + 2;
      if (marker === 0xe0 && length >= 14 && bytes.toString("ascii", data, data + 5) === "JFIF\0") {
        const units = bytes[data + 7];
        const x = bytes.readUInt16BE(data + 8);
        const y = bytes.readUInt16BE(data + 10);
        if (units === 1) pixelRatio = densityRatio(x, y);
        else if (units === 2) pixelRatio = densityRatio(x * 2.54, y * 2.54);
      }
      if (sof.has(marker) && length >= 7) {
        pixelHeight = bytes.readUInt16BE(data + 1);
        pixelWidth = bytes.readUInt16BE(data + 3);
      }
      pos += length;
    }
    return { pixelWidth, pixelHeight, pixelRatio };
  }
  return { ...EMPTY_IMAGE_METRICS };
}

function cachedImageMetrics(path: string, mime: string): ImageMetrics {
  let fd = -1;
  try {
    fd = openSync(path, constants.O_RDONLY | constants.O_NOFOLLOW | constants.O_NONBLOCK);
    const st = fstatSync(fd);
    if (!st.isFile() || st.uid !== process.getuid() || st.size <= 0) return { ...EMPTY_IMAGE_METRICS };
    const header = Buffer.alloc(Math.min(st.size, IMAGE_HEADER_BYTES));
    const count = readSync(fd, header, 0, header.length, 0);
    return imageMetrics(header.subarray(0, count), mime);
  } catch {
    return { ...EMPTY_IMAGE_METRICS };
  } finally {
    if (fd >= 0) closeSync(fd);
  }
}

function evict(keep: string): void {
  let entries: { name: string; bytes: number; mtimeMs: number }[] = [];
  try {
    entries = readdirSync(CACHE_DIR).map((name) => {
      const st = statSync(join(CACHE_DIR, name));
      return { name, bytes: st.size, mtimeMs: st.mtimeMs };
    });
  } catch {
    return;
  }
  for (const name of lruEvictions(entries, CACHE_CAP_BYTES, keep)) {
    try { unlinkSync(join(CACHE_DIR, name)); } catch { /* viewer may hold it; next pass */ }
  }
}

export interface FetchResult {
  ok: boolean;
  online: boolean;
  path: string;
  url: string;
  error: string;
  pixelWidth: number;
  pixelHeight: number;
  pixelRatio: number;
}

export function fetchAttachment(
  id: string,
  name: string,
  mime: string,
  runner = spawnSync,
  maxBytes = FETCH_MAX_BYTES,
): FetchResult {
  const fail = (error: string, online = true): FetchResult =>
    ({ ok: false, online, path: "", url: "", error, ...EMPTY_IMAGE_METRICS });

  if (!/^[0-9]{1,18}$/.test(id)) return fail("bad attachment id");
  mkdirSync(CACHE_DIR, { recursive: true, mode: 0o700 });

  const file = join(CACHE_DIR, cacheFileName(id, name, mime));
  try {
    const st = lstatSync(file);
    // A symlink planted in the cache must never be followed (or touched).
    if (st.isFile() && st.size > 0) {
      const now = new Date();
      utimesSync(file, now, now); // mtime is the LRU clock
      return {
        ok: true, online: true, path: file, url: pathToFileURL(file).href, error: "",
        ...cachedImageMetrics(file, mime),
      };
    }
  } catch { /* not cached */ }

  const args = ["attachment", id, ...(wantsJpeg(mime) ? ["--jpeg"] : [])];
  const res = runner(`${HOME}/bin/imsg`, args, {
    timeout: 120000,
    maxBuffer: FETCH_MAX_BYTES + (1 << 20),
  });
  if (res.status === 69 || res.status === 255) return fail("Mac unreachable", false);
  if (res.status !== 0) {
    const err = (res.stderr || "").toString().trim().split("\n")[0] || `imsg exit ${res.status}`;
    return fail(err);
  }
  const bytes = res.stdout as Buffer;
  if (!bytes || bytes.length === 0) return fail("empty attachment stream");
  if (bytes.length > Math.min(maxBytes, FETCH_MAX_BYTES)) return fail("attachment exceeds the fetch ceiling");

  // tmp + fsync + rename: a killed fetch must never leave a cache hit that
  // looks complete.
  const tmp = `${file}.tmp-${process.pid}`;
  const fd = openSync(tmp, "wx", 0o600);
  try {
    writeSync(fd, bytes);
    fsyncSync(fd);
  } finally {
    closeSync(fd);
  }
  renameSync(tmp, file);
  evict(cacheFileName(id, name, mime));
  return {
    ok: true, online: true, path: file, url: pathToFileURL(file).href, error: "",
    ...imageMetrics(bytes.subarray(0, IMAGE_HEADER_BYTES), mime),
  };
}

if (import.meta.main) {
  const [id, name, mime] = [process.argv[2] ?? "", process.argv[3] ?? "file", process.argv[4] ?? ""];
  const cap = Number(process.argv[5] ?? "");
  try {
    console.log(JSON.stringify(fetchAttachment(id, name, mime, undefined, cap > 0 ? cap : FETCH_MAX_BYTES)));
  } catch (e) {
    console.log(JSON.stringify({ ok: false, online: true, path: "", url: "", error: String(e) }));
  }
}
