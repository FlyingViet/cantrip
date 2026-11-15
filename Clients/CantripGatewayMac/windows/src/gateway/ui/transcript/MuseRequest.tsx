// Home's Muse request (MuseRequestCardView on the Mac, CantripMuseRequestCard in the apps): the exact text Send
// delivers, with Send, Edit and Cancel while it's open. Nothing reaches Muse before Send.
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import type { RemoteMuseRequest } from "../../api/types";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { confirmDialog, toast } from "../kit";

export const MUSE_TEXT_LIMIT = 4000;

/** Runs a card action; a held request's Send asks first (Send anyway). Returns whether it went through. */
export async function museRequestAct(card: RemoteMuseRequest, action: "send" | "edit" | "cancel", text?: string): Promise<boolean> {
  const override = action === "send" && card.state === "held" && text === card.text;
  if (override) {
    const findings = card.findings?.length ? card.findings.join(", ") : "private details";
    const ok = await confirmDialog({
      title: "Send this to Muse anyway?", message: `The Privacy Gate found ${findings}. Muse runs on Meta's servers.`,
      confirm: "Send Anyway", cancel: "Don't Send", destructive: true,
    });
    if (!ok) return false;
  }
  try {
    await remote.museRequestAction(card.id, action, action === "cancel" ? {} : { text, ...(override ? { override: true } : {}) });
    return true;
  } catch (error) {
    toast(`Couldn't ${action} the Muse request: ${(error as Error).message}`);
    return false;
  }
}

export function MuseRequestCard(props: { card: RemoteMuseRequest }): JSX.Element {
  const { card } = props;
  const [draft, setDraft] = useState<string | null>(null);
  const open = (card.actions ?? []).includes("send");
  const busy = remote.isMutating.value;
  const trimmed = draft?.trim() ?? "";
  const label = card.demo ? "Request for your Muse · demo account" : "Request for your Muse";
  return (
    <section class={`muse-card ${card.state}`} role="group" aria-label={`Request for your Muse: ${card.title}`}>
      <span class="muse-label">{label}</span>
      <strong class="muse-title">{card.title}</strong>
      {draft === null
        ? <p class="muse-text selectable">{card.text}</p>
        : <textarea class="muse-editor" value={draft} maxLength={MUSE_TEXT_LIMIT} rows={8} aria-label="Text to send to Muse"
            onInput={(event) => setDraft((event.target as HTMLTextAreaElement).value)} />}
      <p class="muse-status">{draft === null ? card.statusLine : "Send delivers exactly this text. The Privacy Gate checks it again."}</p>
      {open && draft === null ? (
        <div class="row muse-actions">
          <button type="button" class="btn primary" disabled={busy} onClick={() => void museRequestAct(card, "send", card.text)}>
            <Icon name="paperplane" size={14} />{card.sendLabel ?? "Send"}
          </button>
          <button type="button" class="btn" disabled={busy} onClick={() => setDraft(card.text)}><Icon name="pencil" size={14} />Edit</button>
          <button type="button" class="btn" disabled={busy} onClick={() => void museRequestAct(card, "cancel")}><Icon name="xmark" size={14} />Cancel</button>
        </div>
      ) : null}
      {open && draft !== null ? (
        <div class="row muse-actions">
          <button type="button" class="btn primary" disabled={busy || !trimmed || trimmed.length > MUSE_TEXT_LIMIT}
            onClick={() => void museRequestAct(card, "send", trimmed).then((ok) => { if (ok) setDraft(null); })}>
            <Icon name="paperplane" size={14} />Send
          </button>
          <button type="button" class="btn" disabled={busy || !trimmed || trimmed === card.text}
            onClick={() => void museRequestAct(card, "edit", trimmed).then((ok) => { if (ok) setDraft(null); })}>Save</button>
          <button type="button" class="btn" onClick={() => setDraft(null)}>Discard</button>
        </div>
      ) : null}
    </section>
  );
}
