// Full-size image viewer (CantripImageViewer / MacImageViewer): fit or actual size, Esc closes.
import { signal } from "@preact/signals";
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { Icon } from "./icons";
import { Spinner, toast } from "./kit";

/** Copies an image (data: or blob: URL) as PNG: the CSP blocks fetch(data:), and Chromium's
 *  clipboard takes PNG but not JPEG. */
async function copyImage(src: string): Promise<void> {
  const image = new Image();
  image.src = src;
  await image.decode();
  const canvas = document.createElement("canvas");
  canvas.width = image.naturalWidth;
  canvas.height = image.naturalHeight;
  const context = canvas.getContext("2d");
  if (!context) throw new Error("No drawing surface.");
  context.drawImage(image, 0, 0);
  const png = await new Promise<Blob>((resolve, reject) =>
    canvas.toBlob((blob) => (blob ? resolve(blob) : reject(new Error("The image couldn't be converted."))), "image/png"));
  await navigator.clipboard.write([new ClipboardItem({ "image/png": png })]);
}

interface ViewerRequest {
  title: string;
  /** Loads the full image as a URL (data: or blob:). */
  load: () => Promise<string>;
  /** Shown while the full image loads. */
  placeholder?: string;
}

const current = signal<ViewerRequest | null>(null);

export function openViewer(request: ViewerRequest): void {
  current.value = request;
}

export function ImageViewer(): JSX.Element | null {
  const request = current.value;
  const [src, setSrc] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [zoomed, setZoomed] = useState(false);
  const [attempt, setAttempt] = useState(0);
  const closeRef = useRef<HTMLButtonElement>(null);
  const restore = useRef<HTMLElement | null>(null);

  useEffect(() => {
    if (!request) return;
    restore.current = document.activeElement as HTMLElement | null;
    setSrc(request.placeholder ?? null);
    setError(null);
    setZoomed(false);
    let live = true;
    request.load().then((url) => { if (live) setSrc(url); }, (failure: Error) => { if (live) setError(failure.message); });
    requestAnimationFrame(() => closeRef.current?.focus());
    return () => { live = false; };
  }, [request, attempt]);

  if (!request) return null;
  const close = () => {
    current.value = null;
    restore.current?.focus?.();
  };
  return (
    <div class="viewer" role="dialog" aria-modal="true" aria-label={request.title}
      onKeyDown={(event) => { if (event.key === "Escape") { event.stopPropagation(); close(); } }}>
      <div class="viewer-bar">
        <h2 class="truncate">{request.title}</h2>
        {error ? <button type="button" class="btn" onClick={() => setAttempt((value) => value + 1)}>Retry</button> : null}
        <button type="button" class="btn" aria-pressed={zoomed ? "true" : "false"} disabled={!src} onClick={() => setZoomed(!zoomed)}>
          {zoomed ? "Fit to Window" : "Actual Size"}
        </button>
        {src ? (
          <button type="button" class="btn" title="Copy image" onClick={() => {
            copyImage(src).then(() => toast("Copied the image."), (failure: Error) => toast(`Couldn't copy the image: ${failure.message}`));
          }}><Icon name="doc.on.doc" size={14} /> Copy</button>
        ) : null}
        <button ref={closeRef} type="button" class="btn primary" onClick={close}>Done</button>
      </div>
      <div class={`viewer-stage${zoomed ? " zoomed" : ""}`} onClick={(event) => { if (event.target === event.currentTarget) close(); }}>
        {src ? <img src={src} alt={request.title} onClick={() => setZoomed(!zoomed)} /> : !error ? <Spinner size="large" label="Loading image" /> : null}
        {error ? <p class="muted" role="alert" style={{ position: "absolute", bottom: "24px" }}>{src ? `Showing a smaller copy. ${error}` : `Image unavailable. ${error}`}</p> : null}
      </div>
    </div>
  );
}
