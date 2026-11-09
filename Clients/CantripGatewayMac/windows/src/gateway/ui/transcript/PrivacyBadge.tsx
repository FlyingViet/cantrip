// A prompt's Privacy Gate route under its bubble (`RemoteMessage.privacy`): a glyph for the route, the Mac's short label,
// and its reason as the tooltip. Quiet while observing; accent only when enforce mode kept the prompt local. Windows only
// shows the badge: the Privacy Gate is set up on the Mac.
import type { JSX } from "preact";
import type { PrivacyRoute } from "../../api/types";
import { Icon, type IconName } from "../icons";

const ROUTE_ICONS: Record<PrivacyRoute, IconName> = {
  local: "lock.fill", cloud: "cloud.fill", redactApprove: "eye.slash", offline: "shield.slash",
};

/** For a badge whose label is missing. */
const ROUTE_LABELS: Record<PrivacyRoute, string> = {
  local: "Local", cloud: "Cloud", redactApprove: "Ask first", offline: "Privacy check offline",
};

export interface PrivacyBadgeView {
  route: string;
  icon: IconName;
  label: string;
  /** The tooltip ("" when the Mac sent none). */
  detail: string;
  tone: "accent" | "secondary";
  accessibleName: string;
}

function knownRoute(route: string): PrivacyRoute | undefined {
  return Object.hasOwn(ROUTE_ICONS, route) ? (route as PrivacyRoute) : undefined;
}

function text(value: unknown): string {
  return typeof value === "string" ? value.trim() : "";
}

/** How a prompt's badge draws, or null when there's none to draw (older Macs, or not decided yet). */
export function privacyBadgeView(privacy: unknown): PrivacyBadgeView | null {
  if (!privacy || typeof privacy !== "object") return null;
  const value = privacy as Record<string, unknown>;
  const route = text(value.route);
  const known = knownRoute(route);
  const label = text(value.label) || (known ? ROUTE_LABELS[known] : "");
  if (!label) return null;
  return {
    route,
    icon: known ? ROUTE_ICONS[known] : "info.circle",
    label,
    detail: text(value.detail),
    tone: value.mode === "enforce" && route === "local" ? "accent" : "secondary",
    accessibleName: `Privacy: ${label}`,
  };
}

export function PrivacyBadgeLine(props: { privacy: unknown }): JSX.Element | null {
  const view = privacyBadgeView(props.privacy);
  if (!view) return null;
  return (
    <span class={`privacy-badge tone-${view.tone}`} data-route={view.route || undefined} role="img"
      aria-label={view.accessibleName} title={view.detail || undefined}>
      <Icon name={view.icon} size={12} />
      <span class="privacy-label">{view.label}</span>
    </span>
  );
}
