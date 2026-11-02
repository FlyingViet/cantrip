// Live view of the Mac's agent-only Chrome under a reply that used its browser tools
// (`activity.browser`), matching the iOS/Mac card: about one frame a second while the reply is
// running and the card is on screen, the latest view afterwards; click for a larger, faster view.
// View only.
import { signal } from "@preact/signals";
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { browserFrame } from "../../api/client";
import type { BrowserFrame } from "../../api/types";
import { Spinner } from "../kit";
export { usesBrowser } from "./browserPreviewLogic";

const viewerOpen = signal(false);

function frameURL(frame: BrowserFrame): string {
  return `data:image/jpeg;base64,${frame.data}`;
}

export function BrowserCard(props: { live: boolean }): JSX.Element {
  const ref = useRef<HTMLButtonElement>(null);
  const [frame, setFrame] = useState<BrowserFrame | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    let visible = false;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const observer = new IntersectionObserver((entries) => { visible = entries.some((entry) => entry.isIntersecting); });
    if (ref.current) observer.observe(ref.current);
    let loaded = false;
    const tick = async () => {
      if (stopped) return;
      if (visible && !document.hidden && !viewerOpen.value && (props.live || !loaded)) {
        try {
          const next = await browserFrame(560 * (window.devicePixelRatio || 1));
          if (stopped) return;
          setFrame(next);
          setError(null);
          loaded = true;
        } catch (failure) {
          if (!stopped && !loaded) setError(failure instanceof Error ? failure.message : "The agent browser isn't available.");
        }
      }
      timer = setTimeout(tick, props.live ? 900 : 3000);
    };
    timer = setTimeout(tick, 50);
    return () => { stopped = true; clearTimeout(timer); observer.disconnect(); };
  }, [props.live]);

  const caption = frame ? (frame.title || frame.url) : "";
  return (
    <figure class="browser-card">
      <button ref={ref} type="button" onClick={() => { viewerOpen.value = true; }}
        aria-label={props.live ? "Agent browser, live. Open a larger view" : "Agent browser. Open a larger view"}>
        {frame ? <img src={frameURL(frame)} alt="" /> : <span class="browser-empty">{error ?? <><Spinner /> Loading the agent browser…</>}</span>}
        <span class={`browser-badge${props.live ? " live" : ""}`}>{props.live ? "Live" : "Agent Chrome"}</span>
      </button>
      {caption ? <figcaption>{caption}</figcaption> : null}
    </figure>
  );
}

/** Larger live view (about three frames a second). Escape or Done closes it. Mounted once in App. */
export function BrowserViewer(): JSX.Element | null {
  const open = viewerOpen.value;
  const [frame, setFrame] = useState<BrowserFrame | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    if (!open) return;
    let stopped = false;
    let timer: ReturnType<typeof setTimeout> | undefined;
    const tick = async () => {
      if (stopped) return;
      if (!document.hidden) {
        try {
          const next = await browserFrame(window.innerWidth * (window.devicePixelRatio || 1));
          if (stopped) return;
          setFrame(next);
          setError(null);
        } catch (failure) {
          if (!stopped) setError(failure instanceof Error ? failure.message : "The agent browser isn't available.");
        }
      }
      timer = setTimeout(tick, 350);
    };
    const onKey = (event: KeyboardEvent) => { if (event.key === "Escape") { event.stopPropagation(); viewerOpen.value = false; } };
    window.addEventListener("keydown", onKey, true);
    void tick();
    return () => { stopped = true; clearTimeout(timer); window.removeEventListener("keydown", onKey, true); setFrame(null); };
  }, [open]);

  if (!open) return null;
  return (
    <div class="browser-viewer" role="dialog" aria-modal="true" aria-label="Agent browser">
      <div class="browser-viewer-top">
        <span class="browser-viewer-title">{frame?.title || "Agent Chrome"}</span>
        <button type="button" class="primary" onClick={() => { viewerOpen.value = false; }}>Done</button>
      </div>
      <div class="browser-viewer-stage">
        {frame ? <img src={frameURL(frame)} alt="Live view of the agent browser" /> : error ? <span class="browser-empty">{error}</span> : <Spinner />}
      </div>
      {frame ? (
        <div class="browser-viewer-bottom">
          <span class={`browser-badge${frame.active ? " live" : ""}`}>{frame.active ? "Live" : "Agent Chrome"}</span>
          <span class="browser-viewer-url">{frame.url}</span>
        </div>
      ) : null}
    </div>
  );
}
