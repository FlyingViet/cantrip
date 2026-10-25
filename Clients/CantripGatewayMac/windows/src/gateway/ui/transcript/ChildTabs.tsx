// Child tabs (CantripChildTabs.swift): the card a parent shows for each child tab, the banner atop a
// child's conversation, and a queued message's suggested plan.
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import type { ChildTabAction, QueuePlan, RemoteChildResult, RemoteChildTab } from "../../api/types";
import {
  bannerText, chipGlyph, chipTone, conflictLead, conflictOptions, excerptLineKind, extraActions, firstLine, summaryText,
} from "../../state/childTabs";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { confirmDialog, toast } from "../kit";
import { inline } from "./Markdown";

const VERBS: Record<ChildTabAction, string> = {
  open: "open it", discard: "discard it", resolve: "start the merge", keepParent: "keep that version",
  keepChild: "keep that version", leave: "leave it unmerged", retry: "try the merge again", merge: "merge it",
};

async function runAction(parentID: string, child: RemoteChildResult, action: ChildTabAction): Promise<void> {
  const listed = remote.sessions.peek().some((session) => session.id === child.id);
  if (action === "open" && listed) {
    nav.openTab(child.id);
    return;
  }
  if (action === "discard") {
    const ok = await confirmDialog({
      title: `Discard “${child.title}”?`,
      message: child.branch ? `Its work on ${child.branch} is deleted. The conversation stays in history.` : "The conversation stays in history.",
      confirm: "Discard", destructive: true,
    });
    if (!ok) return;
  }
  try {
    await remote.childAction(parentID, child.id, action);
    if (action === "open") nav.openTab(child.id);
  } catch (error) {
    toast(`Couldn't ${VERBS[action]}: ${(error as Error).message}`, 5000);
  }
}

function ChildChip(props: { child: RemoteChildResult }): JSX.Element {
  const { child } = props;
  const working = child.state === "working" || child.state === "merging";
  return (
    <span class={`child-chip ${chipTone(child.state)}`}>
      <span class={working ? "child-pulse" : undefined} aria-hidden="true">{chipGlyph(child.state)}</span>
      {child.statusLine}
    </span>
  );
}

function ConflictExcerpt(props: { text: string }): JSX.Element {
  return (
    <pre class="child-excerpt selectable" tabIndex={0} aria-label="Conflicting lines">
      {props.text.split("\n").map((line, index) => (
        <span key={index} class={excerptLineKind(line)}>{index ? "\n" : ""}{line}</span>
      ))}
    </pre>
  );
}

function ChildQuestion(props: { parentID: string; child: RemoteChildResult; busy: boolean }): JSX.Element {
  const { child } = props;
  const titleID = `child-question-${child.id}`;
  return (
    <div class="child-question" role="group" aria-labelledby={titleID}>
      <h4 id={titleID}>Merge needs your answer</h4>
      <p>Merging <strong>{child.title}</strong> into <code>{child.baseBranch || "the parent's branch"}</code>. {conflictLead(child)}</p>
      {child.conflictExcerpt ? <ConflictExcerpt text={child.conflictExcerpt} /> : null}
      {child.note ? <p class="child-note">{child.note}</p> : null}
      <div class="child-options">
        {conflictOptions(child).map((option) => (
          <button key={option.action} type="button" class={`btn${option.primary ? " primary" : ""}`} disabled={props.busy}
            onClick={() => void runAction(props.parentID, child, option.action)}>
            {option.label}
          </button>
        ))}
      </div>
    </div>
  );
}

/** One card per child in its parent, updated in place from start to merge. */
export function ChildResultCard(props: { parentID: string; child: RemoteChildResult }): JSX.Element {
  const { child, parentID } = props;
  const [open, setOpen] = useState(false);
  const listed = remote.sessions.value.some((session) => session.id === child.id);
  const busy = remote.isMutating.value || !remote.isConnected.value;
  const summary = summaryText(child);
  const tag = firstLine(child.prompt);
  return (
    <section class={`child-card ${child.state}`} role="group" aria-label={`Child tab ${child.title}`}>
      <button type="button" class="child-thread-toggle" aria-expanded={open ? "true" : "false"}
        title="Show the request and the child tab's replies" onClick={() => setOpen(!open)}>
        <span class="child-lane"><Icon name="arrow.triangle.branch" size={12} />Child tab · {child.title}</span>
        <span class="child-tag"><Icon name="arrow.uturn.backward" size={12} /><span class="truncate">{tag}</span>
          <Icon name="chevron.down" size={12} class={open ? "flipped" : undefined} /></span>
      </button>
      {open ? (
        <div class="child-thread">
          <p class="child-prompt selectable">{child.prompt}</p>
          {(child.replies ?? []).map((reply, index) => (
            <div key={index} class="child-reply">
              <span class="child-who">{child.title}</span>
              <p class="selectable">{inline(reply, null, `r${index}`)}</p>
            </div>
          ))}
          {child.files?.length ? (
            <p class="child-files selectable">
              {child.files.slice(0, 8).map((file, index) => (
                <span key={file.path}>{index ? " · " : ""}<code>{file.path}</code> +{file.added} −{file.removed}</span>
              ))}
              {child.files.length > 8 ? ` · ${child.files.length - 8} more` : ""}
            </p>
          ) : null}
          <button type="button" class="btn link child-link" disabled={busy && !listed}
            aria-label={`Open the full conversation of ${child.title}`} onClick={() => void runAction(parentID, child, "open")}>
            Open the full conversation ↗
          </button>
        </div>
      ) : null}
      {summary ? <p class="child-summary selectable">{inline(summary, null, "s")}</p> : null}
      {child.state === "conflict" ? <ChildQuestion parentID={parentID} child={child} busy={busy} /> : null}
      <div class="child-meta">
        <ChildChip child={child} />
        <button type="button" class="btn link child-link" disabled={busy && !listed}
          aria-label={`${listed ? "Open tab" : "Open conversation"}: ${child.title}`} onClick={() => void runAction(parentID, child, "open")}>
          {listed ? "Open tab ↗" : "Open conversation ↗"}
        </button>
        {extraActions(child).map((extra) => (
          <button key={extra.action} type="button" class={`btn small${extra.action === "discard" ? " destructive" : ""}`} disabled={busy}
            onClick={() => void runAction(parentID, child, extra.action)}>
            {extra.label}
          </button>
        ))}
      </div>
    </section>
  );
}

/** Whose child this tab is, its branch and its state, atop its conversation. */
export function ChildBanner(props: { parentID: string; child: RemoteChildTab }): JSX.Element {
  return (
    <div class="child-banner" role="note">
      <Icon name="arrow.triangle.branch" size={14} class="child-glyph" />
      <span class="grow">{bannerText(props.child)}</span>
      <button type="button" class="btn link child-link" aria-label={`Open the parent tab, ${props.child.parentTitle}`}
        onClick={() => nav.openTab(props.parentID)}>
        Open parent
      </button>
    </div>
  );
}

/** A queued message's suggested plan ("Independent: can run in a child tab"). */
export function PlanChip(props: { plan: QueuePlan }): JSX.Element {
  return <span class={`plan-chip ${props.plan.kind}`} title={props.plan.reason}>{props.plan.reason}</span>;
}
