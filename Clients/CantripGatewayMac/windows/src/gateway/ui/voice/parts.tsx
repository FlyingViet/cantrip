// Small pieces shared by the composer's voice controls, Voice Mode and Voice settings.
import type { JSX } from "preact";
import { useEffect, useRef } from "preact/hooks";
import { micLevel } from "./state";

/** SF Symbols' mic / mic.fill. */
export function MicGlyph(props: { filled: boolean; size: number }): JSX.Element {
  return (
    <svg class="voice-glyph" width={props.size} height={props.size} viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <rect x="8.5" y="2" width="7" height="13" rx="3.5" fill={props.filled ? "currentColor" : "none"} />
      <path d="M19 10.5v1a7 7 0 0 1-14 0v-1M12 18.5V22" />
    </svg>
  );
}

/** SF Symbols' checkmark.circle.fill in the accent color. */
export function CheckCircleFill(): JSX.Element {
  return (
    <svg class="voice-check" width="18" height="18" viewBox="0 0 24 24" aria-hidden="true" focusable="false">
      <circle cx="12" cy="12" r="10" />
      <path d="M7.5 12.3l3 3 6-6.3" />
    </svg>
  );
}

const SIZES = {
  small: { bars: 5, min: 6, max: 24 },
  large: { bars: 5, min: 8, max: 32 },
};

/**
 * The Mac's WaveformView: bars that wave while active and lie flat otherwise. `live` follows the
 * microphone's level. Animates outside Preact (no re-renders); still with reduced motion.
 */
export function Waveform(props: { active: boolean; tone: "red" | "accent"; size?: "small" | "large"; live?: boolean }): JSX.Element {
  const ref = useRef<HTMLSpanElement>(null);
  const size = SIZES[props.size ?? "small"];
  useEffect(() => {
    const node = ref.current;
    if (!node) return;
    const bars = Array.from(node.children) as HTMLElement[];
    const set = (amplitudes: (index: number) => number) => {
      bars.forEach((bar, index) => {
        bar.style.height = `${size.min + amplitudes(index) * (size.max - size.min)}px`;
      });
    };
    if (!props.active) {
      set(() => 0.18);
      return;
    }
    const still = matchMedia("(prefers-reduced-motion: reduce)").matches;
    let frame = 0;
    let last = 0;
    const tick = (time: number) => {
      frame = requestAnimationFrame(tick);
      if (time - last < 1000 / 30) return;
      last = time;
      const t = time / 1000;
      const level = props.live ? micLevel.peek() : 1;
      set((index) => {
        const wave = still ? 0.5 : Math.sin(t * 7 + index * 0.9) * 0.5 + 0.5;
        return props.live ? Math.min(1, 0.08 + level * (0.45 + 0.55 * wave)) : wave;
      });
    };
    frame = requestAnimationFrame(tick);
    return () => cancelAnimationFrame(frame);
  }, [props.active, props.live, size]);
  return (
    <span ref={ref} class={`voice-wave ${props.size ?? "small"} ${props.tone}`} aria-hidden="true">
      {Array.from({ length: size.bars }, (_, index) => <span key={index} />)}
    </span>
  );
}
