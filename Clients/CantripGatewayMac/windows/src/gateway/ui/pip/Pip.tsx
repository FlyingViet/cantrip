// Pip on a <canvas>: CantripMascotView for the Windows app. Animates at ~30 fps like the Mac's
// TimelineView, pauses while hidden or scrolled away, and holds a still pose for reduced motion.
import type { JSX } from "preact";
import { useLayoutEffect, useRef } from "preact/hooks";
import { CELEBRATION_DURATION, drawMascot, isBusy, type MascotMood, type OutfitID } from "./mascot";

const FRAME_INTERVAL = 1000 / 30;

export interface PipProps {
  mood: MascotMood;
  outfit: OutfitID;
  /** Width and height in CSS px (the Mac sidebar uses 88 inside a 96 frame). */
  size: number;
  class?: string;
  /** Renders one deterministic frame at this time (seconds), like Swift's `frameTime`, for previews. */
  frameTime?: number;
}

interface Live extends PipProps {
  /** `performance.now()` when the current celebration hop started. */
  celebrationStart: number | null;
}

/** Decorative: the caller labels the control that hosts Pip. */
export function Pip(props: PipProps): JSX.Element {
  const canvasRef = useRef<HTMLCanvasElement>(null);
  const live = useRef<Live>({ ...props, celebrationStart: null });
  const refresh = useRef<() => void>(() => {});
  const previousMood = useRef(props.mood);
  Object.assign(live.current, {
    mood: props.mood, outfit: props.outfit, size: props.size, frameTime: props.frameTime,
  });

  useLayoutEffect(() => {
    const canvas = canvasRef.current;
    const ctx = canvas?.getContext("2d");
    if (!canvas || !ctx) return;
    const reducedMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
    let onScreen = true;
    let frame = 0;
    let lastDraw = -Infinity;
    let celebrationTimer: ReturnType<typeof setTimeout> | undefined;

    /** Swift's `animates`: a live clock, not a pinned frame or Reduce Motion. */
    const animates = () => live.current.frameTime === undefined && !reducedMotion.matches;
    const running = () => animates() && onScreen && !document.hidden;

    const paint = () => {
      const state = live.current;
      const size = Math.max(1, state.size);
      const pixels = Math.max(1, Math.round(size * (window.devicePixelRatio || 1)));
      if (canvas.width !== pixels || canvas.height !== pixels) {
        canvas.width = pixels;
        canvas.height = pixels;
      }
      let celebration: number | null = null;
      if (state.celebrationStart !== null) {
        const elapsed = Math.max(0, (performance.now() - state.celebrationStart) / 1000);
        if (elapsed < CELEBRATION_DURATION) celebration = elapsed;
        else state.celebrationStart = null;
      }
      const motion = animates();
      ctx.setTransform(1, 0, 0, 1, 0, 0);
      ctx.clearRect(0, 0, pixels, pixels);
      ctx.setTransform(pixels / size, 0, 0, pixels / size, 0, 0);
      drawMascot(ctx, {
        mood: state.mood,
        outfit: state.outfit,
        size,
        time: state.frameTime ?? (motion ? Date.now() / 1000 : 1),
        reduceMotion: !motion && state.frameTime === undefined,
        celebration,
      });
    };

    const tick = (now: number) => {
      frame = 0;
      if (!running()) return;
      if (now - lastDraw >= FRAME_INTERVAL - 2) {
        lastDraw = now;
        paint();
      }
      frame = requestAnimationFrame(tick);
    };

    const update = () => {
      if (running()) {
        if (!frame) frame = requestAnimationFrame(tick);
        return;
      }
      if (frame) cancelAnimationFrame(frame);
      frame = 0;
    };

    refresh.current = () => {
      if (!animates() || !document.hidden) {
        paint();
        lastDraw = performance.now();
      }
      // A still pose shows the celebration's happy face until it ends, as the paused TimelineView does.
      clearTimeout(celebrationTimer);
      if (!animates() && live.current.celebrationStart !== null) {
        celebrationTimer = setTimeout(paint, CELEBRATION_DURATION * 1000 + 20);
      }
      update();
    };

    const observer = typeof IntersectionObserver === "function"
      ? new IntersectionObserver((entries) => {
        const entry = entries[entries.length - 1];
        if (!entry) return;
        const wasOnScreen = onScreen;
        onScreen = entry.isIntersecting;
        if (onScreen && !wasOnScreen) refresh.current();
        else update();
      })
      : null;
    observer?.observe(canvas);
    const onVisibility = () => (document.hidden ? update() : refresh.current());
    const onMotionChange = () => refresh.current();
    // Moving between displays changes devicePixelRatio, which fires a resize.
    const onResize = () => {
      const pixels = Math.max(1, Math.round(Math.max(1, live.current.size) * (window.devicePixelRatio || 1)));
      if (canvas.width !== pixels) refresh.current();
    };
    document.addEventListener("visibilitychange", onVisibility);
    reducedMotion.addEventListener("change", onMotionChange);
    window.addEventListener("resize", onResize);
    refresh.current();

    return () => {
      if (frame) cancelAnimationFrame(frame);
      clearTimeout(celebrationTimer);
      observer?.disconnect();
      document.removeEventListener("visibilitychange", onVisibility);
      reducedMotion.removeEventListener("change", onMotionChange);
      window.removeEventListener("resize", onResize);
      refresh.current = () => {};
    };
  }, []);

  useLayoutEffect(() => {
    const previous = previousMood.current;
    previousMood.current = props.mood;
    // Finishing a turn earns a hop: a busy mood settling back to idle.
    if (previous !== props.mood && isBusy(previous) && props.mood === "idle") {
      live.current.celebrationStart = performance.now();
    }
    refresh.current();
  }, [props.mood, props.outfit, props.size, props.frameTime]);

  return (
    <canvas
      ref={canvasRef}
      class={props.class}
      aria-hidden="true"
      style={{
        display: "block",
        width: `${props.size}px`,
        height: `${props.size}px`,
        // `.shadow(color: .black.opacity(0.2), radius: 8, y: 3)`, following the drawn circle's edge.
        filter: "drop-shadow(0 3px 8px rgba(0, 0, 0, 0.2))",
      }}
    />
  );
}
