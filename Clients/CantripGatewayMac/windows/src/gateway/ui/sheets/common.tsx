// Pieces shared by the tool sheets: status labels (SwiftUI `Label`), the leading refresh button,
// polling loops that pause while the window is hidden, and session lookup.
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { RemoteSessionSummary } from "../../api/types";
import * as remote from "../../state/remote";
import { Icon, type IconName } from "../icons";
import { Spinner } from "../kit";
// @ts-ignore -- esbuild bundles CSS imports; TypeScript has no "*.css" module declaration.
import "./sheets.css";

/** `Label(text, systemImage:)`, optionally tinted orange (warnings) or secondary. */
export function StatusLabel(props: {
  icon: IconName; children: ComponentChildren; tone?: "warning" | "secondary" | "accent"; role?: "alert" | "status"; class?: string;
}): JSX.Element {
  return (
    <div class={`sh-label${props.tone ? ` sh-${props.tone}` : ""}${props.class ? ` ${props.class}` : ""}`} role={props.role}>
      <Icon name={props.icon} size={14} />
      <span class="grow selectable">{props.children}</span>
    </div>
  );
}

/** An orange warning with the triangle, announced when it appears. */
export function Warning(props: { children: ComponentChildren; class?: string }): JSX.Element {
  return <StatusLabel icon="exclamationmark.triangle" tone="warning" role="alert" class={props.class}>{props.children}</StatusLabel>;
}

/** `ProgressView(text)` / `HStack { ProgressView(); Text(text) }`. */
export function Loading(props: { text: string }): JSX.Element {
  return (
    <div class="sh-label sh-loading" role="status">
      <Spinner size="small" />
      <span>{props.text}</span>
    </div>
  );
}

/** The toolbar's leading `arrow.clockwise` button. */
export function RefreshButton(props: { label: string; disabled?: boolean; onClick: () => void }): JSX.Element {
  return (
    <button type="button" class="icon-btn sh-refresh" aria-label={props.label} title={props.label} disabled={props.disabled}
      onClick={props.onClick}>
      <Icon name="arrow.clockwise" />
    </button>
  );
}

export function Caption(props: { children: ComponentChildren; class?: string }): JSX.Element {
  return <p class={`sh-caption${props.class ? ` ${props.class}` : ""}`}>{props.children}</p>;
}

/**
 * Runs `run` now, then again after the delay it returns, like the views' `.task` loops. Paused while
 * the window is hidden (macOS scene phase) and resumed at once when it shows again.
 */
export function usePolling(run: () => Promise<number>): void {
  const runRef = useRef(run);
  runRef.current = run;
  useEffect(() => {
    let alive = true;
    let running = false;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const hidden = () => document.visibilityState === "hidden";
    const clear = () => {
      if (timer) clearTimeout(timer);
      timer = null;
    };
    const tick = async () => {
      clear();
      if (!alive || running || hidden()) return;
      running = true;
      let delay = 10000;
      try {
        delay = await runRef.current();
      } catch {
        // Each run reports its own errors.
      } finally {
        running = false;
      }
      if (alive && !hidden()) timer = setTimeout(() => void tick(), delay);
    };
    const onVisibility = () => {
      if (hidden()) clear();
      else void tick();
    };
    document.addEventListener("visibilitychange", onVisibility);
    void tick();
    return () => {
      alive = false;
      clear();
      document.removeEventListener("visibilitychange", onVisibility);
    };
  }, []);
}

/** False once the component unmounts (results arriving after the sheet closed are dropped). */
export function useAlive(): { readonly current: boolean } {
  const alive = useRef(true);
  useEffect(() => {
    alive.current = true;
    return () => { alive.current = false; };
  }, []);
  return alive;
}

/** Re-renders every `milliseconds` (SwiftUI `TimelineView(.periodic)`); returns the current time. */
export function useTick(milliseconds: number): number {
  const [time, setTime] = useState(Date.now());
  useEffect(() => {
    const timer = setInterval(() => setTime(Date.now()), milliseconds);
    return () => clearInterval(timer);
  }, [milliseconds]);
  return time;
}

/** A tab, Home, or a cached hidden session by ID. */
export function findSession(id: string): RemoteSessionSummary | null {
  return remote.sessions.value.find((item) => item.id === id)
    ?? (remote.homeSummary.value?.id === id ? remote.homeSummary.value : null)
    ?? remote.details.value.get(id)
    ?? null;
}

export function sleep(milliseconds: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, milliseconds));
}
