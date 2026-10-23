// Filled status circles the shared icon set lacks (SF Symbols' pause/stop/forward/xmark .circle.fill in
// other tints), and the small inline glyphs the activity views need.
import type { JSX } from "preact";

export type GlyphKind = "pause" | "stop" | "forward" | "xmark" | "check" | "question";

const TINTS = {
  blue: "var(--accent)", gray: "rgba(235,235,245,.45)", green: "var(--green)", red: "var(--red)", orange: "var(--active-tint)",
} as const;

export function FilledGlyph(props: { kind: GlyphKind; tint: keyof typeof TINTS; size?: number; label?: string }): JSX.Element {
  const size = props.size ?? 16;
  const glyph = (() => {
    switch (props.kind) {
      case "pause": return <path d="M10 8.5v7M14 8.5v7" stroke="#fff" stroke-width="2.2" stroke-linecap="round" />;
      case "stop": return <rect x="8.6" y="8.6" width="6.8" height="6.8" rx="1.2" fill="#fff" />;
      case "forward": return <path d="M7.5 8.5l4 3.5-4 3.5zM12.5 8.5l4 3.5-4 3.5z" fill="#fff" stroke="#fff" stroke-width="1" stroke-linejoin="round" />;
      case "xmark": return <path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="#fff" stroke-width="2.2" stroke-linecap="round" />;
      case "check": return <path d="M7.5 12.3l3 3 6-6.3" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round" />;
      case "question": return <text x="12" y="16.6" text-anchor="middle" font-size="13" font-weight="800" fill="#fff" font-family="Segoe UI, system-ui">?</text>;
    }
  })();
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" class="status-icon" role={props.label ? "img" : undefined}
      aria-label={props.label} aria-hidden={props.label ? undefined : "true"} focusable="false">
      <circle cx="12" cy="12" r="11" fill={TINTS[props.tint]} />
      {glyph}
    </svg>
  );
}

/** SF Symbols' arrow.up.circle (Send now). */
export function ArrowUpCircle(props: { size?: number }): JSX.Element {
  const size = props.size ?? 18;
  return (
    <svg class="icon" style={{ width: `${size}px`, height: `${size}px` }} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="10" />
      <path d="m16 12-4-4-4 4" />
      <path d="M12 16V8" />
    </svg>
  );
}

/** SF Symbols' questionmark.bubble.fill. */
export function QuestionBubble(props: { size?: number; label?: string }): JSX.Element {
  const size = props.size ?? 18;
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" class="act-question-bubble" role={props.label ? "img" : undefined}
      aria-label={props.label} aria-hidden={props.label ? undefined : "true"} focusable="false">
      <path d="M12 2.5c5.5 0 9.5 3.7 9.5 8.3s-4 8.3-9.5 8.3c-1 0-2-.1-2.9-.4L4.6 21l1.1-3.9C3.7 15.6 2.5 13.3 2.5 10.8 2.5 6.2 6.5 2.5 12 2.5z" fill="var(--active-tint)" />
      <text x="12" y="15.2" text-anchor="middle" font-size="11.5" font-weight="800" fill="#1c1200" font-family="Segoe UI, system-ui">?</text>
    </svg>
  );
}
