// Icons: Lucide outlines standing in for the Mac app's SF Symbols, keyed by SF Symbol-like names.
import {
  Activity, Antenna, Archive, ArrowDown, ArrowUp, ArrowUpDown, AudioWaveform, Bell, Bot, Box, Brain, Calendar, Check,
  ChevronDown, ChevronLeft, ChevronRight, ChevronUp, Circle, CircleCheck, CircleDot, CircleEllipsis, CircleHelp,
  CirclePause, CirclePlay, CirclePlus, CircleStop, CircleX, Clock, Cog, Copy, Download, Ellipsis, Eraser, ExternalLink,
  Eye, EyeOff, File, FileText, Film, Folder, FolderOpen, FolderPlus, Gauge, GripVertical, Hammer, History, Hourglass, House, Image,
  Images, Info, KeyRound, Layers, LayoutGrid, Link, ListChecks, ListOrdered, Lock, LogOut, MessagesSquare, Mic, Monitor,
  PanelLeft, Paperclip, Pause, Pencil, Play, Plus, Power, RadioTower, RotateCw, Rows3, Search, Send, Server, Settings,
  Settings2, Shirt, ShieldCheck, SlidersHorizontal, Sparkles, Square, SquareArrowOutUpRight, Star, Terminal, Timer, Trash2,
  TriangleAlert, Undo2, Unlink, UserRound, Volume2, Wifi, WifiOff, Wrench, X, Zap,
} from "lucide";
import type { IconNode } from "lucide";
import type { JSX } from "preact";

const ICONS = {
  "bubble.left.and.bubble.right": MessagesSquare, checklist: ListChecks, "square.grid.2x2": LayoutGrid,
  "gearshape.2": Cog, gearshape: Settings, "gearshape.alt": Settings2, "arrow.clockwise": RotateCw,
  "ellipsis.circle": CircleEllipsis, ellipsis: Ellipsis, plus: Plus, "plus.circle": CirclePlus, house: House,
  "chevron.down": ChevronDown, "chevron.right": ChevronRight, "chevron.left": ChevronLeft, "chevron.up": ChevronUp,
  mic: Mic, waveform: AudioWaveform, "stop.fill": Square, "stop.circle": CircleStop, "lock.fill": Lock,
  "lock.shield.fill": ShieldCheck, "sidebar.left": PanelLeft, "slider.horizontal.3": SlidersHorizontal,
  "gauge.with.dots.needle.33percent": Gauge, "pause.circle": CirclePause, "play.circle": CirclePlay, play: Play, pause: Pause,
  hammer: Hammer, brain: Brain, tshirt: Shirt, "antenna.radiowaves.left.and.right": RadioTower, antenna: Antenna,
  "checkmark.circle": CircleCheck, "xmark.circle": CircleX, "exclamationmark.triangle": TriangleAlert,
  "questionmark.circle": CircleHelp, clock: Clock, trash: Trash2, pencil: Pencil, "doc.text": FileText, photo: Image,
  "photo.on.rectangle": Images, film: Film, paperclip: Paperclip, "arrow.up.forward.square": SquareArrowOutUpRight,
  "arrow.up.right": ExternalLink, "arrow.down": ArrowDown, "arrow.up": ArrowUp, xmark: X, "doc.on.doc": Copy,
  magnifyingglass: Search, "rectangle.stack": Layers, sparkles: Sparkles, tray: Archive, "arrow.uturn.backward": Undo2,
  folder: Folder, "folder.open": FolderOpen, "folder.badge.plus": FolderPlus, "arrow.down.circle": Download, desktopcomputer: Monitor, key: KeyRound,
  "list.number": ListOrdered, terminal: Terminal, "info.circle": Info, checkmark: Check, wrench: Wrench,
  "paperplane": Send, eraser: Eraser, bolt: Zap, hourglass: Hourglass, bell: Bell, calendar: Calendar, link: Link,
  "link.slash": Unlink, "wifi.slash": WifiOff, wifi: Wifi, "speaker.wave.2": Volume2, eye: Eye, "eye.slash": EyeOff,
  "line.3.horizontal": GripVertical, "arrow.up.arrow.down": ArrowUpDown, star: Star, shippingbox: Box, doc: File,
  "rectangle.portrait.and.arrow.right": LogOut, power: Power, waveformPath: Activity, cpu: Bot, person: UserRound,
  "record.circle": CircleDot, circle: Circle, timer: Timer, "clock.arrow.circlepath": History, "list.bullet": Rows3,
  server: Server,
} satisfies Record<string, IconNode>;

export type IconName = keyof typeof ICONS;

export function Icon(props: { name: IconName; size?: 12 | 14 | 16 | 18 | 20 | 22 | 24 | 28 | 56; class?: string; label?: string }): JSX.Element {
  const node = ICONS[props.name] as IconNode;
  const size = props.size && props.size !== 16 ? ` s${props.size}` : "";
  return (
    <svg
      class={`icon${size}${props.class ? ` ${props.class}` : ""}`}
      viewBox="0 0 24 24"
      aria-hidden={props.label ? undefined : "true"}
      role={props.label ? "img" : undefined}
      aria-label={props.label}
      focusable="false"
    >
      {node.map(([tag, attrs], index) => {
        const Tag = tag as "path";
        return <Tag key={index} {...(attrs as Record<string, string>)} />;
      })}
    </svg>
  );
}

/** Filled status circles like SF Symbols' checkmark.circle.fill / xmark.circle.fill. */
export type StatusKind =
  | "succeeded" | "failed" | "cancelled" | "running" | "queued" | "idle" | "needsInput" | "paused" | "warning" | "off";

const STATUS_COLORS: Record<StatusKind, string> = {
  succeeded: "var(--green)", failed: "var(--red)", cancelled: "rgba(235,235,245,.45)", running: "var(--accent)",
  queued: "rgba(235,235,245,.45)", idle: "rgba(235,235,245,.45)", needsInput: "var(--orange)", paused: "var(--orange)",
  warning: "var(--orange)", off: "rgba(235,235,245,.3)",
};

export function StatusIcon(props: { kind: StatusKind; size?: number; label?: string }): JSX.Element {
  const size = props.size ?? 16;
  const color = STATUS_COLORS[props.kind];
  const glyph = (() => {
    switch (props.kind) {
      case "succeeded": return <path d="M7.5 12.3l3 3 6-6.3" stroke="#fff" stroke-width="2.2" fill="none" stroke-linecap="round" stroke-linejoin="round" />;
      case "failed": return <path d="M8.5 8.5l7 7M15.5 8.5l-7 7" stroke="#fff" stroke-width="2.2" stroke-linecap="round" />;
      case "cancelled": return <path d="M8 12h8" stroke="#fff" stroke-width="2.2" stroke-linecap="round" />;
      case "needsInput": return <text x="12" y="16.6" text-anchor="middle" font-size="13" font-weight="800" fill="#fff" font-family="Segoe UI, system-ui">?</text>;
      case "warning": return <text x="12" y="16.6" text-anchor="middle" font-size="13" font-weight="800" fill="#fff" font-family="Segoe UI, system-ui">!</text>;
      case "paused": return <path d="M10 8.5v7M14 8.5v7" stroke="#fff" stroke-width="2.2" stroke-linecap="round" />;
      case "queued": return <path d="M12 7.5V12l3 2" stroke="#fff" stroke-width="2" fill="none" stroke-linecap="round" />;
      case "running": return <circle cx="12" cy="12" r="3" fill="#fff" />;
      default: return null;
    }
  })();
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" class="status-icon" role={props.label ? "img" : undefined}
      aria-label={props.label} aria-hidden={props.label ? undefined : "true"} focusable="false">
      <circle cx="12" cy="12" r="11" fill={color} />
      {glyph}
    </svg>
  );
}
