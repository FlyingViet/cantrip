// Attachments, prepared and uploaded the way the Mac client does (API.md §4-5):
// images → metadata-free JPEG ≤2048 px, ≤1 MiB, inline in the message; files and videos →
// resumable 1 MiB chunk uploads verified by SHA-256, then referenced by ID.
import { api, bytesToBase64, pathComponent } from "../../api/client";
import type { FileUploadResponse, VideoPrepareResponse, VideoUploadResponse } from "../../api/types";

export const MAX_IMAGES = 4;
export const MAX_FILES = 5;
export const MAX_UPLOAD_BYTES = 100 << 20;
export const MAX_VIDEO_SECONDS = 300;
const MAX_IMAGE_BYTES = 1 << 20;
const MAX_SIDE = 2048;
const CHUNK = 1 << 20;

export interface ImageDraft {
  id: string;
  /** Base64 JPEG ready to send. */
  data: string;
  /** Object URL for the preview. */
  preview: string;
  name: string;
}

export interface FileDraft {
  id: string;
  file: File;
  name: string;
  size: number;
}

export interface VideoDraft {
  id: string;
  file: File;
  name: string;
  size: number;
  duration: number;
  format: "mov" | "mp4";
}

export class AttachmentError extends Error {}

function decodeImage(blob: Blob): Promise<ImageBitmap> {
  return createImageBitmap(blob, { imageOrientation: "from-image" }).catch(() => {
    throw new AttachmentError("This image couldn't be read. Try a PNG or JPEG.");
  });
}

/** Re-encodes an image as a metadata-free JPEG within the Mac's limits (ImageAttachments.swift:82-117). */
export async function prepareImage(blob: Blob, name = "Image"): Promise<ImageDraft> {
  const bitmap = await decodeImage(blob);
  let scale = Math.min(1, MAX_SIDE / Math.max(bitmap.width, bitmap.height));
  for (let attempt = 0; attempt < 4; attempt++) {
    const width = Math.max(1, Math.round(bitmap.width * scale));
    const height = Math.max(1, Math.round(bitmap.height * scale));
    const canvas = new OffscreenCanvas(width, height);
    const context = canvas.getContext("2d")!;
    context.fillStyle = "#fff";
    context.fillRect(0, 0, width, height);
    context.drawImage(bitmap, 0, 0, width, height);
    for (const quality of [0.9, 0.75, 0.6, 0.45]) {
      const jpeg = await canvas.convertToBlob({ type: "image/jpeg", quality });
      if (jpeg.size <= MAX_IMAGE_BYTES) {
        bitmap.close();
        const bytes = new Uint8Array(await jpeg.arrayBuffer());
        return { id: crypto.randomUUID(), data: bytesToBase64(bytes), preview: URL.createObjectURL(jpeg), name };
      }
    }
    scale *= 0.7;
  }
  bitmap.close();
  throw new AttachmentError("This image is too large to send, even after shrinking it.");
}

export function isImageFile(file: File): boolean {
  return /^image\/(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(file.type) || /\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(file.name);
}

export function isVideoFile(file: File): boolean {
  return /\.(mov|mp4)$/i.test(file.name) || file.type === "video/mp4" || file.type === "video/quicktime";
}

export function prepareFile(file: File): FileDraft {
  if (file.size > MAX_UPLOAD_BYTES) throw new AttachmentError(`${file.name} is larger than 100 MB.`);
  if (file.size === 0) throw new AttachmentError(`${file.name} is empty.`);
  return { id: crypto.randomUUID().toUpperCase(), file, name: cleanName(file.name), size: file.size };
}

export async function prepareVideo(file: File): Promise<VideoDraft> {
  if (file.size > MAX_UPLOAD_BYTES) throw new AttachmentError("Videos must be 100 MB or smaller.");
  const format = /\.mov$/i.test(file.name) || file.type === "video/quicktime" ? "mov" : "mp4";
  const duration = await new Promise<number>((resolve) => {
    const video = document.createElement("video");
    const url = URL.createObjectURL(file);
    video.preload = "metadata";
    video.onloadedmetadata = () => { URL.revokeObjectURL(url); resolve(video.duration); };
    video.onerror = () => { URL.revokeObjectURL(url); resolve(NaN); };
    video.src = url;
  });
  if (Number.isFinite(duration) && duration > MAX_VIDEO_SECONDS) throw new AttachmentError("Videos must be 5 minutes or shorter.");
  return { id: crypto.randomUUID().toUpperCase(), file, name: cleanName(file.name), size: file.size, duration: Number.isFinite(duration) ? duration : 0, format };
}

function cleanName(name: string): string {
  // eslint-disable-next-line no-control-regex
  return (name.split(/[\\/]/).pop() ?? "file").replace(/[\u0000-\u001f\u007f]/g, "").slice(0, 160) || "file";
}

async function sha256(file: File): Promise<string> {
  // Files are ≤100 MB, so one digest over the whole buffer is fine.
  const digest = await crypto.subtle.digest("SHA-256", await file.arrayBuffer());
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

function query(values: Record<string, string | number>): string {
  return Object.entries(values).map(([key, value]) => `${key}=${encodeURIComponent(String(value))}`).join("&");
}

export interface UploadProgress {
  label: string;
  fraction: number;
}

/** Uploads (or resumes) one file or video in 1 MiB chunks. */
async function upload(
  kind: "files" | "videos", sessionID: string, draft: FileDraft | VideoDraft, onProgress: (sent: number) => void, signal: AbortSignal,
): Promise<void> {
  const base = `/api/v1/sessions/${pathComponent(sessionID)}/${kind}/${pathComponent(draft.id)}`;
  const hash = await sha256(draft.file);
  let offset = 0;
  try {
    const status = await api<FileUploadResponse | VideoUploadResponse>(base, { signal });
    if (status.upload.totalBytes === draft.size && status.upload.sha256 === hash) offset = status.upload.receivedBytes;
  } catch (error) {
    if ((error as { status?: number }).status !== 404) throw error;
  }
  onProgress(offset);
  while (offset < draft.size) {
    if (signal.aborted) throw new AttachmentError("Upload cancelled.");
    const chunk = new Uint8Array(await draft.file.slice(offset, offset + CHUNK).arrayBuffer());
    const params: Record<string, string | number> = { offset, totalBytes: draft.size, name: draft.name, sha256: hash };
    if (kind === "videos") params.format = (draft as VideoDraft).format;
    const response = await api<FileUploadResponse | VideoUploadResponse>(`${base}?${query(params)}`, { method: "PUT", raw: chunk, signal, timeoutMs: 120000 });
    const received = response.upload.receivedBytes;
    if (received < offset + chunk.length || received > draft.size) throw new AttachmentError("The Mac reported an unexpected upload size.");
    offset = received;
    onProgress(offset);
  }
  if (kind === "videos") {
    const prepared = await api<VideoPrepareResponse>(`${base}/prepare`, { method: "POST", signal, timeoutMs: 180000 });
    if (!prepared.ready) throw new AttachmentError("The Mac couldn't prepare this video.");
  }
}

export async function uploadAttachments(
  sessionID: string, video: VideoDraft | null, files: FileDraft[], onProgress: (progress: UploadProgress | null) => void, signal: AbortSignal,
): Promise<{ videoID?: string; fileIDs?: string[] }> {
  const items = [...(video ? [{ kind: "videos" as const, draft: video }] : []), ...files.map((draft) => ({ kind: "files" as const, draft }))];
  const total = items.reduce((sum, item) => sum + item.draft.size, 0);
  let done = 0;
  for (const item of items) {
    await upload(item.kind, sessionID, item.draft, (sent) => {
      onProgress({ label: `Uploading ${item.draft.name}…`, fraction: total ? (done + sent) / total : 1 });
    }, signal);
    done += item.draft.size;
  }
  onProgress(null);
  return { videoID: video?.id, fileIDs: files.length ? files.map((file) => file.id) : undefined };
}
