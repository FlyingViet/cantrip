// @-mention a tab (state/tabMentions): the suggestion list above the composer while "@query" is typed (the
// slash-command popover's look and keyboard model: the text field keeps focus, the list is its listbox via
// aria-activedescendant), the chips of picked mentions, and tokens drawn as "@Label" in transcripts.
import type { AriaAttributes, JSX } from "preact";
import { useEffect, useId, useLayoutEffect, useState } from "preact/hooks";
import type { RemoteSessionSummary } from "../../api/types";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import {
  matchMentions, mentionAccessibilityLabel, mentionCandidates, mentionCountAnnouncement, mentionDetail, mentionListState, mentionQuery,
  mentionSegments, moveMentionHighlight, noMentionMatchText, supportsMentions, type MentionCandidate, type TabMention,
} from "../../state/tabMentions";
import { Icon } from "../icons";

export interface TabMentionSuggestions {
  /** The list is showing. */
  open: boolean;
  /** ARIA attributes for the composer's text field while the list shows. */
  fieldProps: AriaAttributes;
  /** Handles a key in the text field; true when the list used it (the composer then ignores it). */
  onKeyDown(event: KeyboardEvent): boolean;
  /** The list (null when closed), placed above the composer. */
  popover: JSX.Element | null;
  /** Polite live region: the count when the list opens, the pick after one. Always rendered. */
  announcer: JSX.Element;
}

export function useTabMentions(options: {
  session: RemoteSessionSummary | null;
  text: string;
  /** The text field's caret (UTF-16 offset), or null while a range is selected. */
  caret: number | null;
  /** The composer is focused. */
  focused: boolean;
  /** The composer accepts text now. */
  enabled: boolean;
  /** Replaces text[at..<caret] with the picked tab's "@Label ". */
  onPick(candidate: MentionCandidate, at: number, caret: number): void;
}): TabMentionSuggestions {
  const { session, text, caret } = options;
  const sessionID = session?.id ?? null;
  const listID = `mention-list-${useId()}`;
  /** Escape or a pick closes the list for one "@" (session and position) until the caret leaves it. */
  const [dismissed, setDismissed] = useState<string | null>(null);
  const [moved, setMoved] = useState<{ key: string; id: string } | null>(null);
  const [picked, setPicked] = useState("");

  const query = supportsMentions(session) && caret !== null ? mentionQuery(text, caret) : null;
  const place = query ? `${sessionID}:${query.at}` : null;
  const found = query && options.focused && options.enabled ? query : null;
  // Functional: an Escape handled before this effect runs must not be undone by its older `place`.
  useEffect(() => {
    setDismissed((current) => (current !== null && current !== place ? null : current));
  }, [place]);

  const candidates = found ? mentionCandidates(remote.sessions.value, sessionID) : [];
  const matches = found ? matchMentions(found.query, candidates) : [];
  const state = found ? mentionListState(found.query, matches, candidates.length) : "hidden";
  const open = found !== null && state !== "hidden" && dismissed !== place;
  const key = found ? `${place}|${found.query}` : "";
  // "Mentioned X" is said once, right after a pick; the list opening again announces its count.
  useEffect(() => {
    if (open && picked) setPicked("");
  }, [open, picked]);

  let highlighted = open && matches.length ? 0 : -1;
  if (highlighted >= 0 && moved && moved.key === key) {
    const index = matches.findIndex((match) => match.id === moved.id);
    if (index >= 0) highlighted = index;
  }
  const optionID = (index: number) => `${listID}-${index}`;

  // Keeps the highlighted row visible by scrolling the list only (never the page around it).
  useLayoutEffect(() => {
    const row = highlighted >= 0 ? document.getElementById(optionID(highlighted)) : null;
    const list = row?.parentElement;
    if (!row || !list) return;
    const top = row.offsetTop;
    if (top < list.scrollTop) list.scrollTop = top;
    else if (top + row.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = top + row.offsetHeight - list.clientHeight;
  }, [highlighted, open]);

  const pick = (index: number) => {
    const candidate = matches[index];
    if (!candidate || !found || caret === null) return;
    setMoved(null);
    // "@Label " is itself a query that matches the pick: keep the list closed for this "@".
    setDismissed(place);
    setPicked(`Mentioned ${candidate.title}`);
    options.onPick(candidate, found.at, caret);
  };

  const onKeyDown = (event: KeyboardEvent): boolean => {
    if (!open || event.isComposing || event.ctrlKey || event.metaKey || event.altKey) return false;
    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp": {
        if (event.shiftKey || !matches.length) return false;
        event.preventDefault();
        const next = moveMentionHighlight(matches.length, highlighted, event.key === "ArrowDown" ? 1 : -1);
        setMoved({ key, id: matches[next].id });
        return true;
      }
      case "Tab":
      case "Enter":
        // Shift+Enter keeps adding a new line; with no row to pick, Return sends as typed.
        if (event.shiftKey || highlighted < 0) return false;
        event.preventDefault();
        pick(highlighted);
        return true;
      case "Escape":
        event.preventDefault();
        event.stopPropagation();
        setDismissed(place);
        return true;
      default:
        return false;
    }
  };

  const announcement = open ? (matches.length ? mentionCountAnnouncement(matches.length) : noMentionMatchText(found!.query)) : picked;
  const fieldProps: AriaAttributes = {
    "aria-autocomplete": "list",
    "aria-haspopup": "listbox",
    "aria-expanded": open,
    "aria-controls": open ? listID : undefined,
    "aria-activedescendant": highlighted >= 0 ? optionID(highlighted) : undefined,
  };

  const popover = open ? (
    // Pressing in the list keeps focus (and the list) in the composer.
    <div class="slash-popover mention-popover" data-id="chat.tabMentions" onMouseDown={(event) => event.preventDefault()}>
      <div class="slash-header" aria-hidden="true">Tabs</div>
      <div id={listID} class="slash-list" role="listbox" aria-label="Tab suggestions">
        {matches.map((candidate, index) => (
          <MentionRow key={candidate.id} id={optionID(index)} candidate={candidate} selected={index === highlighted} onPick={() => pick(index)} />
        ))}
      </div>
      {state === "empty" ? <div class="slash-info">{noMentionMatchText(found!.query)}</div> : null}
    </div>
  ) : null;

  return {
    open,
    fieldProps,
    onKeyDown,
    popover,
    announcer: <div class="sr-only" role="status" aria-live="polite" aria-atomic="true">{announcement}</div>,
  };
}

function MentionRow(props: { id: string; candidate: MentionCandidate; selected: boolean; onPick: () => void }): JSX.Element {
  const { candidate } = props;
  const detail = mentionDetail(candidate);
  return (
    <div id={props.id} role="option" class={`slash-row mention-row${props.selected ? " selected" : ""}`} aria-selected={props.selected}
      aria-label={mentionAccessibilityLabel(candidate)} onClick={props.onPick}>
      <Icon name={candidate.isChild ? "arrow.triangle.branch" : "rectangle.stack"} size={14} class="mention-row-icon" />
      <span class="mention-row-text">
        <span class="mention-row-title">{candidate.title}</span>
        {detail ? <span class="mention-row-detail">{detail}</span> : null}
      </span>
      {props.selected ? <span class="mention-row-key" aria-hidden="true">↵</span> : null}
    </div>
  );
}

/** One chip per picked mention above the composer; removing one also removes its "@Label" text. */
export function MentionChips(props: { mentions: readonly TabMention[]; disabled: boolean; onRemove(mention: TabMention): void }): JSX.Element | null {
  if (!props.mentions.length) return null;
  return (
    <div class="attachments mention-chips" role="list" aria-label="Mentioned tabs">
      {props.mentions.map((mention) => (
        <span key={`${mention.id}:${mention.label}`} role="listitem" class="attachment-chip mention-chip" title={`Sent with the ID of the tab “${mention.label}”`}>
          <Icon name="rectangle.stack" size={14} />
          <span class="truncate">@{mention.label}</span>
          <button type="button" class="icon-btn" aria-label={`Remove mention ${mention.label}`} title="Remove mention" disabled={props.disabled}
            onClick={() => props.onRemove(mention)}>
            <Icon name="xmark" size={12} />
          </button>
        </span>
      ))}
    </div>
  );
}

/** A mention in a transcript: "@Label", styled; opens the tab when it's in the tab list. */
export function MentionPill(props: { label: string; id: string }): JSX.Element {
  const text = `@${props.label}`;
  const id = props.id.toUpperCase();
  const target = remote.sessions.value.find((session) => session.id.toUpperCase() === id);
  if (!target) return <span class="mention" title="Mentioned tab">{text}</span>;
  return (
    <button type="button" class="mention" title={`Open the tab “${remote.tabTitle(target)}”`} aria-label={`${text}, mentioned tab. Opens it`}
      onClick={() => nav.openTab(target.id)}>
      {text}
    </button>
  );
}

/** Plain message text with its tokens drawn as mentions. */
export function MentionText(props: { text: string }): JSX.Element {
  return (
    <>
      {mentionSegments(props.text).map((segment, index) => (
        segment.kind === "text" ? segment.text : <MentionPill key={`m${index}`} label={segment.label} id={segment.id} />
      ))}
    </>
  );
}
