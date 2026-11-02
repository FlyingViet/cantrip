// Pieces shared by Home's Tasks and Artifacts panes: the availability gate, empty states, the orange
// error line, run summaries, and the in-pane navigation bar.
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useLayoutEffect, useRef } from "preact/hooks";
import { Icon } from "../icons";
import { openMenu, Spinner, type MenuEntry } from "../kit";
import { homeAvailability } from "./homeState";
import { summaryLabelLength, summaryLines } from "./homeLogic";
import { WarningGlyph } from "./symbols";
import "./home.css";

/** ContentUnavailableView: a large glyph, a title, a description and an optional action. */
export function Unavailable(props: { icon?: ComponentChildren; title: string; description?: ComponentChildren; action?: ComponentChildren; error?: string | null }): JSX.Element {
  return (
    <div class="hm-unavailable">
      {props.icon ? <div class="hm-unavailable-icon" aria-hidden="true">{props.icon}</div> : null}
      <h2>{props.title}</h2>
      {props.description ? <p>{props.description}</p> : null}
      {props.error ? <ErrorLine text={props.error} /> : null}
      {props.action ? <div class="hm-unavailable-action">{props.action}</div> : null}
    </div>
  );
}

/** Label(error, systemImage: "exclamationmark.triangle.fill") in orange caption text. */
export function ErrorLine(props: { text: string | null | undefined; class?: string }): JSX.Element | null {
  if (!props.text) return null;
  return (
    <div class={`hm-error${props.class ? ` ${props.class}` : ""}`} role="alert">
      <WarningGlyph size={13} />
      <span class="selectable">{props.text}</span>
    </div>
  );
}

/** Shows Home's section once Home's chat session is open; otherwise why it isn't. */
export function HomeGate(props: { children: () => ComponentChildren }): JSX.Element {
  const availability = homeAvailability();
  if (availability.state === "opening") {
    return (
      <div class="hm-root">
        <div class="hm-unavailable" role="status">
          <Spinner size="large" />
          <p>Opening Cantrip Home…</p>
        </div>
      </div>
    );
  }
  if (availability.state === "unavailable") {
    return (
      <div class="hm-root">
        <Unavailable icon={<HouseSlash />} title="Cantrip Home unavailable" description={availability.message} />
      </div>
    );
  }
  return <>{props.children()}</>;
}

function HouseSlash(): JSX.Element {
  return (
    <span class="hm-house-slash">
      <Icon name="house" size={56} />
      <svg class="icon s56" viewBox="0 0 24 24" aria-hidden="true" focusable="false"><path d="M3 3l18 18" /></svg>
    </span>
  );
}

/**
 * A task run's summary (CantripHomeRunSummaryText): one line wraps up to `lineLimit` lines; a "Summary:" section's
 * short lines show one per row with the "Label:" emphasized.
 */
export function RunSummary(props: { summary: string; lineLimit?: number; class?: string }): JSX.Element {
  const lines = summaryLines(props.summary);
  const clamp = props.lineLimit ? { WebkitLineClamp: String(props.lineLimit) } : undefined;
  const lineClass = props.lineLimit ? "hm-clamp" : "hm-wrap";
  if (lines.length < 2) {
    return <span class={`hm-run-summary ${lineClass}${props.class ? ` ${props.class}` : ""}`} style={clamp}>{props.summary}</span>;
  }
  return (
    <span class={`hm-run-summary hm-run-lines${props.class ? ` ${props.class}` : ""}`}>
      {lines.map((line, index) => {
        const label = summaryLabelLength(line);
        return (
          <span key={index} class={lineClass} style={clamp}>
            {label ? <><strong>{line.slice(0, label)}</strong>{line.slice(label)}</> : line}
          </span>
        );
      })}
    </span>
  );
}

/** The pushed view's title bar inside the pane (the window toolbar stays "Tasks"). */
export function PaneBar(props: { backLabel: string; onBack: () => void; title: string; children?: ComponentChildren }): JSX.Element {
  const titleRef = useRef<HTMLHeadingElement>(null);
  useEffect(() => { titleRef.current?.focus({ preventScroll: true }); }, []);
  return (
    <div class="hm-bar">
      <button type="button" class="btn plain hm-back" onClick={props.onBack} title={`Back to ${props.backLabel} (Alt+Left)`}
        aria-label={`Back to ${props.backLabel}`}>
        <Icon name="chevron.left" size={16} />
        <span class="truncate">{props.backLabel}</span>
      </button>
      <h2 ref={titleRef} class="hm-bar-title truncate" tabIndex={-1}>{props.title}</h2>
      {props.children}
    </div>
  );
}

/** A scrolling area that remembers its position per key (going Back lands where you were). */
export function ScrollArea(props: {
  scrollKey: string;
  saved: (key: string) => number;
  onSave: (key: string, top: number) => void;
  class?: string;
  children: ComponentChildren;
  onRendered?: (element: HTMLDivElement) => void;
}): JSX.Element {
  const ref = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    if (ref.current) ref.current.scrollTop = props.saved(props.scrollKey);
  }, [props.scrollKey]);
  useEffect(() => {
    if (ref.current) props.onRendered?.(ref.current);
  });
  return (
    <div ref={ref} class={`hm-scroll${props.class ? ` ${props.class}` : ""}`}
      onScroll={(event) => props.onSave(props.scrollKey, (event.currentTarget as HTMLDivElement).scrollTop)}>
      {props.children}
    </div>
  );
}

/** A context menu at the pointer, or at the element when opened from the keyboard. */
export function contextMenuAt(event: MouseEvent, entries: MenuEntry[], label: string): void {
  event.preventDefault();
  const target = event.currentTarget as HTMLElement;
  let point = { x: event.clientX, y: event.clientY };
  if (!point.x && !point.y) {
    const box = target.getBoundingClientRect();
    point = { x: box.left + 24, y: box.top + 24 };
  }
  openMenu(point, entries, { label });
}
