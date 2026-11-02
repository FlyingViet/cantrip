// Rename Tab (CantripTabRenameSheet, CantripTabActions.swift): up to 80 characters; blank uses the
// automatic name. Saved through POST …/metadata like the Mac.
import type { JSX } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useId, useRef, useState } from "preact/hooks";
import * as remote from "../../state/remote";
import { FormRow, FormSection, Sheet } from "../kit";
import { Warning, findSession, useAlive } from "./common";
import { initialTabName, normalizeTabName, tabNameError, writeFailure } from "./sheetLogic";

export function RenameSheet(props: { sessionID: string; onClose: () => void }): JSX.Element | null {
  return <RenameForm key={props.sessionID} sessionID={props.sessionID} onClose={props.onClose} />;
}

function RenameForm(props: { sessionID: string; onClose: () => void }): JSX.Element {
  const [name, setName] = useState(() => {
    const session = findSession(props.sessionID);
    return session ? initialTabName(session) : "";
  });
  const saving = useSignal(false);
  const error = useSignal<string | null>(null);
  const alive = useAlive();
  const input = useRef<HTMLInputElement>(null);
  const formID = useId();
  const fieldID = useId();
  const busy = saving.value || remote.isMutating.value;

  useEffect(() => {
    requestAnimationFrame(() => input.current?.select());
  }, []);

  const save = async () => {
    if (saving.value || remote.isMutating.value) return;
    const session = findSession(props.sessionID);
    if (!session) {
      error.value = "This tab is no longer on the Mac.";
      return;
    }
    const problem = tabNameError(name);
    if (problem) {
      error.value = problem;
      return;
    }
    if (session.supportsTabMetadata !== true) {
      error.value = "Update and reopen Cantrip on your Mac to rename or lock its tabs.";
      return;
    }
    saving.value = true;
    try {
      await remote.updateTab(props.sessionID, { customTitle: normalizeTabName(name) });
      if (alive.current) props.onClose();
    } catch (failure) {
      if (alive.current) error.value = writeFailure(failure) || "The tab could not be renamed.";
    } finally {
      saving.value = false;
    }
  };

  return (
    <Sheet title="Rename Tab" onClose={props.onClose} width={420} height={220} locked={saving.value}
      footer={<>
        <button type="button" class="btn" disabled={saving.value} onClick={props.onClose}>Cancel</button>
        <button type="submit" form={formID} class="btn primary" disabled={busy}>Save</button>
      </>}>
      <form id={formID} onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <FormSection footer="Up to 80 characters. Leave blank to use the automatic name.">
          <FormRow label={<label for={fieldID}>Tab name</label>}>
            <input ref={input} id={fieldID} class="text-field sh-control" type="text" value={name} placeholder="Tab name"
              disabled={saving.value} data-autofocus autocomplete="off" spellcheck={false}
              aria-describedby={error.value ? `${fieldID}-error` : undefined}
              onInput={(event) => { setName(event.currentTarget.value); error.value = null; }} />
          </FormRow>
        </FormSection>
        {error.value ? <div id={`${fieldID}-error`}><Warning>{error.value}</Warning></div> : null}
      </form>
    </Sheet>
  );
}
