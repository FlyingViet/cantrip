// Artifact thumbnails (CantripArtifactThumbnailStore): memory first, then this PC's disk cache (IndexedDB), then
// one request per artifact revision, at most three at a time. Failures are remembered until the next manual
// refresh so a re-render never retries in a loop.
import { effect } from "@preact/signals";
import { api, base64ToBytes, pathComponent } from "../../api/client";
import type { HomeArtifact, HomeArtifactDataResponse, HomeArtifactThumbnailResponse } from "../../api/types";
import * as remote from "../../state/remote";
import { artifactKey, supportsThumbnail } from "./homeLogic";

export interface Thumbnail {
  /** data: URL of the JPEG. */
  src: string;
  durationSeconds?: number;
}

const MAXIMUM_BYTES = 1 << 20;
const MEMORY_ENTRIES = 200;
const DISK_ENTRIES = 300;
const CONCURRENT_FETCHES = 3;

const memory = new Map<string, Thumbnail>();
/** Full images for the viewer (a few, in memory). */
const fullImages = new Map<string, string>();
const unavailable = new Set<string>();
const inFlight = new Map<string, Promise<Thumbnail | null>>();
let generation = 0;
let running = 0;
const waiters: (() => void)[] = [];

function remember(key: string, value: Thumbnail): void {
  memory.delete(key);
  memory.set(key, value);
  while (memory.size > MEMORY_ENTRIES) memory.delete(memory.keys().next().value!);
}

export function cachedThumbnail(artifact: HomeArtifact): Thumbnail | null {
  return memory.get(artifactKey(artifact)) ?? null;
}

export function isThumbnailUnavailable(artifact: HomeArtifact): boolean {
  return unavailable.has(artifactKey(artifact));
}

async function acquire(): Promise<void> {
  if (running < CONCURRENT_FETCHES) {
    running++;
    return;
  }
  await new Promise<void>((resolve) => waiters.push(resolve));
}

function release(): void {
  const next = waiters.shift();
  if (next) next();
  else running--;
}

function decodes(src: string): Promise<boolean> {
  const image = new Image();
  image.src = src;
  return image.decode().then(() => image.naturalWidth > 0, () => false);
}

export function loadThumbnail(artifact: HomeArtifact): Promise<Thumbnail | null> {
  if (!supportsThumbnail(artifact)) return Promise.resolve(null);
  const key = artifactKey(artifact);
  const hit = memory.get(key);
  if (hit) return Promise.resolve(hit);
  if (unavailable.has(key)) return Promise.resolve(null);
  const pending = inFlight.get(key);
  if (pending) return pending;
  const started = generation;
  const task = (async (): Promise<Thumbnail | null> => {
    const disk = await readDisk(key);
    if (started !== generation) return null;
    if (disk) {
      remember(key, disk);
      return disk;
    }
    await acquire();
    let payload: HomeArtifactThumbnailResponse | null;
    try {
      if (started !== generation) return null;
      payload = await api<HomeArtifactThumbnailResponse>(`/api/v1/home/artifacts/${pathComponent(artifact.id)}/thumbnail`);
    } catch (error) {
      // 404: a document, unreadable media, or a Mac that predates thumbnails. Other failures wait for a refresh too.
      if (started === generation) unavailable.add(key);
      return null;
    } finally {
      release();
    }
    if (started !== generation) return null;
    const valid = payload && payload.data && payload.width > 0 && payload.height > 0
      && Math.floor((payload.data.length * 3) / 4) <= MAXIMUM_BYTES;
    const value: Thumbnail | null = valid ? { src: `data:image/jpeg;base64,${payload!.data}`, durationSeconds: payload!.durationSeconds ?? undefined } : null;
    if (!value || !(await decodes(value.src)) || started !== generation) {
      if (started === generation) unavailable.add(key);
      return null;
    }
    remember(key, value);
    void writeDisk(key, value, started);
    return value;
  })().finally(() => {
    if (started === generation) inFlight.delete(key);
  });
  inFlight.set(key, task);
  return task;
}

/** A manual refresh tries failed thumbnails again. */
export function resetThumbnailFailures(): void {
  unavailable.clear();
}

export function forgetThumbnail(artifact: HomeArtifact): void {
  const key = artifactKey(artifact);
  memory.delete(key);
  unavailable.delete(key);
  fullImages.delete(key);
  void deleteDisk(key);
}

/** Pairing with another Mac drops every thumbnail, on disk too. */
export function removeAllThumbnails(): void {
  generation++;
  inFlight.clear();
  unavailable.clear();
  memory.clear();
  fullImages.clear();
  void clearDisk();
}

// remote.reset() (a different Mac) empties the artifacts list; a first launch starts empty, so only a drop counts.
let hadArtifacts = false;
effect(() => {
  const has = remote.homeArtifacts.value !== null;
  if (hadArtifacts && !has && !remote.listed.value) removeAllThumbnails();
  hadArtifacts = has;
});

// MARK: Full files and images

export async function loadArtifactData(artifact: HomeArtifact): Promise<{ data: string; mimeType: string }> {
  const response = await api<HomeArtifactDataResponse>(`/api/v1/home/artifacts/${pathComponent(artifact.id)}`);
  if (!response?.data || response.artifact?.id?.toUpperCase() !== artifact.id.toUpperCase()) {
    throw new Error("The Mac sent an unexpected reply.");
  }
  return { data: response.data, mimeType: response.artifact.mimeType || artifact.mimeType || "application/octet-stream" };
}

export async function loadArtifactImage(artifact: HomeArtifact): Promise<string> {
  const key = artifactKey(artifact);
  const cached = fullImages.get(key);
  if (cached) return cached;
  const started = generation;
  const { data, mimeType } = await loadArtifactData(artifact);
  const url = `data:${mimeType.startsWith("image/") ? mimeType : artifact.mimeType || "image/png"};base64,${data}`;
  if (started === generation) {
    fullImages.set(key, url);
    while (fullImages.size > 4) fullImages.delete(fullImages.keys().next().value!);
  }
  return url;
}

export function artifactBlob(data: string, mimeType: string): Blob {
  return new Blob([base64ToBytes(data) as BlobPart], { type: mimeType });
}

// MARK: Disk cache (IndexedDB), newest 300 kept

const DB_NAME = "cantrip-artifact-thumbnails";
const STORE = "thumbnails";
let database: Promise<IDBDatabase | null> | null = null;

function open(): Promise<IDBDatabase | null> {
  database ??= new Promise((resolve) => {
    try {
      const request = indexedDB.open(DB_NAME, 1);
      request.onupgradeneeded = () => {
        const store = request.result.createObjectStore(STORE, { keyPath: "key" });
        store.createIndex("savedAt", "savedAt");
      };
      request.onsuccess = () => resolve(request.result);
      request.onerror = () => resolve(null);
      request.onblocked = () => resolve(null);
    } catch {
      resolve(null);
    }
  });
  return database;
}

function done<T>(request: IDBRequest<T>): Promise<T | null> {
  return new Promise((resolve) => {
    request.onsuccess = () => resolve(request.result);
    request.onerror = () => resolve(null);
  });
}

interface DiskEntry { key: string; src: string; durationSeconds?: number; savedAt: number }

async function readDisk(key: string): Promise<Thumbnail | null> {
  const db = await open();
  if (!db) return null;
  try {
    const entry = await done<DiskEntry | undefined>(db.transaction(STORE).objectStore(STORE).get(key));
    return entry?.src ? { src: entry.src, durationSeconds: entry.durationSeconds } : null;
  } catch {
    return null;
  }
}

async function writeDisk(key: string, value: Thumbnail, started: number): Promise<void> {
  const db = await open();
  if (!db || started !== generation) return;
  try {
    const store = db.transaction(STORE, "readwrite").objectStore(STORE);
    await done(store.put({ key, src: value.src, durationSeconds: value.durationSeconds, savedAt: Date.now() } satisfies DiskEntry));
    const count = await done(db.transaction(STORE).objectStore(STORE).count());
    if (count !== null && count > DISK_ENTRIES) {
      const oldest = await done(db.transaction(STORE).objectStore(STORE).index("savedAt").getAllKeys(null, count - DISK_ENTRIES));
      const prune = db.transaction(STORE, "readwrite").objectStore(STORE);
      for (const old of oldest ?? []) prune.delete(old);
    }
    // Unpaired while writing: don't leave the old Mac's thumbnail behind.
    if (started !== generation) await deleteDisk(key);
  } catch { /* the network copy still shows */ }
}

async function deleteDisk(key: string): Promise<void> {
  const db = await open();
  if (!db) return;
  try { await done(db.transaction(STORE, "readwrite").objectStore(STORE).delete(key)); } catch { /* ignore */ }
}

async function clearDisk(): Promise<void> {
  const db = await open();
  if (!db) return;
  try { await done(db.transaction(STORE, "readwrite").objectStore(STORE).clear()); } catch { /* ignore */ }
}
