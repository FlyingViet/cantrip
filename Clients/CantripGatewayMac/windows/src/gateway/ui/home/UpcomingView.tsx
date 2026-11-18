// Home's Tasks → Upcoming (docs/cantrip-home.md "Upcoming"): everything set to run later, grouped as Next up (6 until
// Show all), Waiting, Repeating and Paused under a collapsible heading with its count, between Views and Tasks. Each
// row's small button is the Mac's Cancel, Stop or Pause (asked first with the Mac's own question, Keep backs out) or
// Resume (at once); the answer replaces the list and its message shows as a toast. Shown only while the Mac serves it.
import { computed, signal } from "@preact/signals";
import type { JSX } from "preact";
import { api } from "../../api/client";
import type { HomeUpcomingItem } from "../../api/types";
import { now } from "../../state/clock";
import * as remote from "../../state/remote";
import { parseUpcoming, upcomingAction, upcomingActionRequest, upcomingMeta, upcomingQuestion, upcomingSections } from "../../state/upcoming";
import { confirmDialog, toast } from "../kit";
import { ErrorLine, SectionHeading } from "./parts";
import * as tasksNav from "./tasksNav";

/** Next up lists everything once Show all is pressed, until the window closes. */
export const showAllUpcoming = signal(false);
/** The item whose Cancel or Resume is in flight. */
export const upcomingBusy = signal<string | null>(null);
/** The last failed Cancel or Resume, until the next one. */
export const upcomingActionError = signal<string | null>(null);
/** "Today"/"Tomorrow" change with the minute at most, so rows redraw once a minute, not every tick. */
const minute = computed(() => Math.floor(now.value / 60_000));
function message(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

/** Once the section has redrawn (Preact renders on the next tick), focuses the first of `keys` it finds. */
function focusAfterRender(keys: string[]): void {
  setTimeout(() => {
    const root = globalThis.document?.getElementById?.("hm-upcoming");
    for (const key of keys) {
      const target = root?.querySelector<HTMLElement>(`[data-focus-key="${CSS.escape(key)}"]`);
      if (target) {
        target.focus();
        return;
      }
    }
  }, 0);
}

/** Cancel, Stop or Pause once the user confirms with the Mac's question; Resume at once. */
export async function runUpcomingAction(item: HomeUpcomingItem): Promise<boolean> {
  const action = upcomingAction(item);
  if (!action || upcomingBusy.peek()) return false;
  if (action.kind === "cancel") {
    const confirmed = await confirmDialog({ title: upcomingQuestion(item, action.label), confirm: action.label, cancel: "Keep", destructive: true });
    if (!confirmed) return false;
  }
  const before = (remote.homeUpcoming.peek() ?? []).map((entry) => entry.id);
  const request = upcomingActionRequest(action.kind, item.id);
  upcomingBusy.value = item.id;
  upcomingActionError.value = null;
  try {
    const parsed = parseUpcoming(await remote.mutate(() => api<unknown>(request.path, { method: "POST", body: request.body })));
    if (!parsed.unchanged) {
      remote.applyUpcoming(parsed.items, parsed.revision);
      // The item's button (now Resume or Pause) or row, else the next row still drawn (a cancelled step leaves, a
      // resumed task may move past Show all), else the heading.
      const following = before.slice(before.indexOf(item.id) + 1).map((id) => `upcoming-row:${id}`);
      focusAfterRender([`upcoming:${item.id}`, `upcoming-row:${item.id}`, ...following, "section:hm-upcoming-title"]);
      if (parsed.message) toast(parsed.message);
    }
    return true;
  } catch (error) {
    upcomingActionError.value = `Couldn't ${action.label.toLowerCase()} “${item.title}”: ${message(error)}`;
    return false;
  } finally {
    upcomingBusy.value = null;
  }
}

/** "Upcoming · 12" above Tasks: null while the Mac doesn't serve the list (an older Mac). */
export function UpcomingSection(): JSX.Element | null {
  const items = remote.homeUpcoming.value;
  if (items === null) return null;
  const collapsed = tasksNav.sectionCollapsed("upcoming");
  const error = upcomingActionError.value ?? remote.homeUpcomingError.value;
  const at = new Date(minute.value * 60_000);
  const busy = upcomingBusy.value;
  const sections = collapsed ? [] : upcomingSections(items, showAllUpcoming.value);
  return (
    <section id="hm-upcoming" class="hm-upcoming" aria-labelledby="hm-upcoming-title">
      <SectionHeading id="hm-upcoming-title" title="Upcoming" count={items.length} noun={["item", "items"]} collapsed={collapsed}
        controls="hm-upcoming-body" onToggle={() => tasksNav.toggleSection("upcoming")} alwaysCount />
      <div id="hm-upcoming-body" class="hm-section-body" hidden={collapsed}>
        {collapsed ? null : (
          <>
            <ErrorLine text={error} class="hm-upcoming-error" />
            {items.length ? null : <p class="hm-upcoming-empty">Nothing scheduled</p>}
            {sections.map((section) => (
              <div key={section.id} class="hm-upcoming-group">
                <h4 id={`hm-upcoming-${section.id}`} class="hm-upcoming-group-title">{section.title}</h4>
                <ul class="hm-upcoming-list" aria-labelledby={`hm-upcoming-${section.id}`}>
                  {section.items.map((item) => <UpcomingRow key={item.id} item={item} at={at} busy={busy === item.id} />)}
                </ul>
                {section.items.length < section.total ? (
                  <button type="button" class="btn small hm-upcoming-more" data-focus-key="upcoming-more"
                    aria-label={`Show all ${section.total} in ${section.title}`}
                    onClick={() => {
                      const first = upcomingSections(items, true).find((all) => all.id === section.id)?.items[section.items.length];
                      showAllUpcoming.value = true;
                      if (first) focusAfterRender([`upcoming-row:${first.id}`]);
                    }}>
                    Show all {section.total}
                  </button>
                ) : null}
              </div>
            ))}
          </>
        )}
      </div>
    </section>
  );
}

/** One item: its title, when (or its schedule) · schedule · who set it up, its detail, and its one button. */
export function UpcomingRow(props: { item: HomeUpcomingItem; at: Date; busy: boolean }): JSX.Element {
  const { item, busy } = props;
  const action = upcomingAction(item);
  return (
    <li class="hm-upcoming-row" tabIndex={-1} data-focus-key={`upcoming-row:${item.id}`}>
      <div class="hm-upcoming-text">
        <span class="hm-upcoming-title">{item.title}</span>
        <span class="hm-upcoming-meta">{upcomingMeta(item, props.at)}</span>
        {item.detail ? <span class="hm-upcoming-detail">{item.detail}</span> : null}
      </div>
      {action ? (
        <button type="button" class="btn small hm-upcoming-action" data-focus-key={`upcoming:${item.id}`}
          aria-label={`${action.label} ${item.title}`} aria-haspopup={action.kind === "cancel" ? "dialog" : undefined}
          aria-disabled={busy ? "true" : undefined} aria-busy={busy ? "true" : undefined}
          onClick={() => void runUpcomingAction(item)}>
          {action.label}
        </button>
      ) : null}
    </li>
  );
}
