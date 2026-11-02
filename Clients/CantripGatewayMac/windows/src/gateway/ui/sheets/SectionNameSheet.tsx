// New Section / Rename Section (CantripTabSections.swift): up to 40 characters, unique on the Mac.
import type { JSX } from "preact";
import { useSignal } from "@preact/signals";
import { useEffect, useId, useRef, useState } from "preact/hooks";
import { MAX_SECTION_NAME, normalizeSectionName, sectionNameError } from "../../state/sections";
import * as remote from "../../state/remote";
import { FormRow, FormSection, Sheet } from "../kit";
import { Warning, useAlive } from "./common";
import { writeFailure } from "./sheetLogic";

export function SectionNameSheet(props: { sectionID?: string; fileTabID?: string; onClose: () => void }): JSX.Element {
  const existing = remote.tabSections.value.find((section) => section.id === props.sectionID) ?? null;
  const [name, setName] = useState(existing?.name ?? "");
  const saving = useSignal(false);
  const error = useSignal<string | null>(null);
  const alive = useAlive();
  const input = useRef<HTMLInputElement>(null);
  const formID = useId();
  const fieldID = useId();
  const tab = props.fileTabID ? remote.sessions.value.find((item) => item.id === props.fileTabID) : undefined;

  useEffect(() => {
    requestAnimationFrame(() => input.current?.select());
  }, []);

  const save = async () => {
    if (saving.value || remote.isMutating.value) return;
    const problem = sectionNameError(name);
    if (problem) {
      error.value = problem;
      return;
    }
    saving.value = true;
    try {
      if (existing) await remote.renameSection(existing.id, normalizeSectionName(name));
      else await remote.createSection(normalizeSectionName(name), props.fileTabID);
      if (alive.current) props.onClose();
    } catch (failure) {
      if (alive.current) error.value = writeFailure(failure) || (failure as Error).message || "The section could not be saved.";
    } finally {
      saving.value = false;
    }
  };

  const footer = existing ? `Up to ${MAX_SECTION_NAME} characters.`
    : `Sections group tabs on every device.${tab ? ` ${remote.tabTitle(tab)} moves into it.` : ""} Up to ${MAX_SECTION_NAME} characters.`;
  return (
    <Sheet title={existing ? "Rename Section" : "New Section"} onClose={props.onClose} width={420} height={220} locked={saving.value}
      footer={<>
        <button type="button" class="btn" disabled={saving.value} onClick={props.onClose}>Cancel</button>
        <button type="submit" form={formID} class="btn primary" disabled={saving.value || remote.isMutating.value}>
          {existing ? "Save" : "Create"}
        </button>
      </>}>
      <form id={formID} onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <FormSection footer={footer}>
          <FormRow label={<label for={fieldID}>Section name</label>}>
            <input ref={input} id={fieldID} class="text-field sh-control" type="text" value={name} placeholder="Section name"
              disabled={saving.value} data-autofocus autocomplete="off" spellcheck={false} maxLength={MAX_SECTION_NAME * 2}
              aria-describedby={error.value ? `${fieldID}-error` : undefined}
              onInput={(event) => { setName(event.currentTarget.value); error.value = null; }} />
          </FormRow>
        </FormSection>
        {error.value ? <div id={`${fieldID}-error`}><Warning>{error.value}</Warning></div> : null}
      </form>
    </Sheet>
  );
}
