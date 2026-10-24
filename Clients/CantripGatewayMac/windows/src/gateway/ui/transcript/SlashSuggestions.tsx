// Slash-command suggestions above the composer: the tab backend's commands, custom commands and
// skills while the text is "/token" (rules in state/slashCommands). The text field keeps focus;
// the list is its listbox (aria-activedescendant), driven by Up/Down, Tab, Return and Escape.
import type { AriaAttributes, JSX } from "preact";
import { useEffect, useId, useLayoutEffect, useState } from "preact/hooks";
import type { RemoteSessionSummary } from "../../api/types";
import { commandsCache, commandsVersion } from "../../state/commands";
import {
  chooseCommand, commandHint, commandLabel, commandTitle, countAnnouncement, defaultHighlight, firstChoosable, isUnavailable, matchCommands,
  moveHighlight, slashToken, type CommandChoice, type CommandMatch,
} from "../../state/slashCommands";
import { Spinner } from "../kit";

export interface SlashSuggestions {
  /** The list is showing. */
  open: boolean;
  /** ARIA attributes for the composer's text field. */
  fieldProps: AriaAttributes;
  /** Handles a key in the text field; true when the list used it (the composer then ignores it). */
  onKeyDown(event: KeyboardEvent): boolean;
  /** The list (null when closed), placed above the composer. */
  popover: JSX.Element | null;
  /** Polite live region announcing the count; always rendered so changes are read. */
  announcer: JSX.Element;
}

export function useSlashSuggestions(options: {
  session: RemoteSessionSummary | null;
  text: string;
  /** The composer is focused. */
  focused: boolean;
  /** The composer accepts text now. */
  enabled: boolean;
  /** Applies a chosen row (new text, then send or open model settings). */
  onChoose(choice: CommandChoice): void;
}): SlashSuggestions {
  const { session, text } = options;
  const sessionID = session?.id ?? null;
  const listID = `slash-list-${useId()}`;
  const [dismissed, setDismissed] = useState<{ sessionID: string | null; text: string } | null>(null);
  const [moved, setMoved] = useState<{ sessionID: string | null; text: string; name: string } | null>(null);
  // Re-render when a cached list or its loading state changes.
  void commandsVersion.value;

  const supported = session?.supportsBackendCommands === true;
  const token = slashToken(text);
  const slashMode = token !== null;

  // Fetch on the first slash entry, and prefetch when the composer is focused (the cache decides
  // whether a fetch is due: first time, older than 30 s, or the backend changed).
  useEffect(() => {
    if (session && supported && (slashMode || options.focused)) commandsCache.refresh(session);
  }, [sessionID, supported, slashMode, options.focused, session?.workdir, session?.modelSettingsRevision]);

  const state = session && supported ? commandsCache.get(session.id) : null;
  const active = slashMode && supported && options.focused && options.enabled
    && !(dismissed && dismissed.sessionID === sessionID && dismissed.text === text);
  const matches: CommandMatch[] = active && state?.response ? matchCommands(state.response.commands, token!) : [];
  const loading = active && !state?.response && Boolean(state?.loading);
  const status = active ? state?.response?.status?.trim() || null : null;
  const open = active && (loading || matches.length > 0 || status !== null);

  let highlighted = open ? defaultHighlight(matches, token!) : null;
  if (open && moved && moved.sessionID === sessionID && moved.text === text) {
    const index = matches.findIndex((match) => match.command.name === moved.name && !isUnavailable(match.command));
    if (index >= 0) highlighted = index;
  }
  const optionID = (index: number) => `${listID}-${index}`;
  const canOpenModelSettings = session?.supportsModelSettings === true;

  // Keeps the highlighted row visible by scrolling the list only (never the page around it).
  useLayoutEffect(() => {
    const row = highlighted !== null ? document.getElementById(optionID(highlighted)) : null;
    const list = row?.parentElement;
    if (!row || !list) return;
    const top = row.offsetTop;
    if (top < list.scrollTop) list.scrollTop = top;
    else if (top + row.offsetHeight > list.scrollTop + list.clientHeight) list.scrollTop = top + row.offsetHeight - list.clientHeight;
  }, [highlighted, open]);

  const choose = (index: number, via: "tab" | "return") => {
    const match = matches[index];
    const choice = match ? chooseCommand(match.command, via, canOpenModelSettings) : null;
    if (!choice) return;
    setMoved(null);
    options.onChoose(choice);
  };

  const onKeyDown = (event: KeyboardEvent): boolean => {
    if (!open || event.isComposing) return false;
    const modified = event.ctrlKey || event.metaKey || event.altKey;
    switch (event.key) {
      case "ArrowDown":
      case "ArrowUp": {
        if (modified || event.shiftKey) return false;
        const next = moveHighlight(matches, highlighted, event.key === "ArrowDown" ? 1 : -1);
        if (next === null) return false;
        event.preventDefault();
        setMoved({ sessionID, text, name: matches[next].command.name });
        return true;
      }
      case "Tab": {
        if (modified || event.shiftKey) return false;
        const index = highlighted ?? firstChoosable(matches);
        if (index === null) return false;
        event.preventDefault();
        choose(index, "tab");
        return true;
      }
      case "Enter":
        // Shift+Enter keeps adding a new line; nothing highlighted sends the text as typed.
        if (event.shiftKey || event.altKey || highlighted === null) return false;
        event.preventDefault();
        choose(highlighted, "return");
        return true;
      case "Escape":
        event.preventDefault();
        event.stopPropagation();
        setDismissed({ sessionID, text });
        return true;
      default:
        return false;
    }
  };

  const backend = state?.response?.backend?.trim();
  const listLabel = backend ? `${backend} commands` : "Commands";
  const announcement = !open ? "" : loading ? "Loading commands…" : matches.length ? countAnnouncement(matches.length) : status ?? "";

  const fieldProps: AriaAttributes = {
    "aria-autocomplete": "list",
    "aria-haspopup": "listbox",
    "aria-expanded": open,
    "aria-controls": open ? listID : undefined,
    "aria-activedescendant": highlighted !== null ? optionID(highlighted) : undefined,
  };

  const popover = open ? (
    // Pressing in the list keeps focus (and the list) in the composer.
    <div class="slash-popover" data-id="chat.slashCommands" onMouseDown={(event) => event.preventDefault()}>
      {backend ? <div class="slash-header" aria-hidden="true">{listLabel}</div> : null}
      <div id={listID} class="slash-list" role="listbox" aria-label={listLabel}>
        {matches.map((match, index) => (
          <SlashRow key={`${match.index}:${match.command.name}`} id={optionID(index)} match={match} selected={index === highlighted}
            hint={commandHint(match.command, canOpenModelSettings)} onChoose={() => choose(index, "return")} />
        ))}
      </div>
      {loading ? <div class="slash-info"><Spinner size="small" />Loading commands…</div> : null}
      {status ? <div class="slash-info">{status}</div> : null}
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

function SlashRow(props: { id: string; match: CommandMatch; selected: boolean; hint: string | null; onChoose: () => void }): JSX.Element {
  const { command } = props.match;
  const unavailable = isUnavailable(command);
  const note = command.note?.trim();
  const inputHint = command.inputHint?.trim();
  return (
    <div id={props.id} role="option" class={`slash-row${props.selected ? " selected" : ""}${unavailable ? " unavailable" : ""}`}
      aria-selected={props.selected} aria-disabled={unavailable || undefined} aria-label={commandLabel(command)}
      aria-description={props.hint ?? undefined} title={unavailable && note ? note : undefined}
      onClick={() => { if (!unavailable) props.onChoose(); }}>
      <div class="slash-line">
        <span class="slash-name">{commandTitle(command)}</span>
        {inputHint ? <span class="slash-input-hint">{inputHint}</span> : null}
        <span class="slash-description">{command.description}</span>
        {command.source?.trim() ? <span class="slash-source">{command.source}</span> : null}
      </div>
      {note && (unavailable || command.availability === "cantrip") ? <div class="slash-note">{note}</div> : null}
    </div>
  );
}
