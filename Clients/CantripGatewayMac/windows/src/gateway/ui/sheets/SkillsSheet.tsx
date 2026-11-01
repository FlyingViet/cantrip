// Skills & Rules (CantripSkillsView, CantripSkills.swift): the one skills library Cantrip on the Mac gives
// every backend, its folder rules and their drift. Skills are Mac-wide; they're edited on the Mac.
import { useEffect, useRef, useState } from "preact/hooks";
import { api } from "../../api/client";
import type { SkillsAction } from "../../api/types";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { FormRow, FormSection, Sheet } from "../kit";
import { Caption, Loading, useAlive, useTick } from "./common";
import {
  SKILLS_EDIT_COMMAND, SKILLS_EXPLAINER_LEAD, SKILLS_TITLE, SKILLS_UNSUPPORTED, type SkillsState, errorText, isUnsupported,
  normalizeSkills, skillSeenBy, skillToggleLabel, skillsDriftClear, skillsDriftStatus, skillsDriftSummary, skillsPollDelay,
  skillsRelinkSummary, skillsRuleText, skillsWithEnabled,
} from "./sheetLogic";

const RELINK_SHOWN_MS = 8000;

/** A warning line: icon plus text (and "Warning:" for screen readers), never color alone. */
function Warning(props: { text: string }) {
  return (
    <p class="sh-warning sk-warning">
      <Icon name="exclamationmark.triangle" size={14} />
      <span><span class="sr-only">Warning: </span>{props.text}</span>
    </p>
  );
}

export function SkillsSheet(props: { onClose: () => void }) {
  const [snapshot, setSnapshot] = useState<SkillsState | null>(null);
  const [error, setError] = useState("");
  const [busy, setBusy] = useState<string | null>(null);
  const [relinked, setRelinked] = useState<string[] | null>(null);
  const [announcement, setAnnouncement] = useState("");
  const alive = useAlive();
  const now = useTick(30000);
  const latest = useRef<SkillsState | null>(null);
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined);
  const stopped = useRef(false);
  const working = useRef(false);

  function show(value: SkillsState): void {
    if (latest.current?.checking && !value.checking) setAnnouncement(skillsDriftSummary(value));
    latest.current = value;
    setSnapshot(value);
  }

  function fail(failure: unknown): void {
    // An older Mac: say so once and stop asking.
    if (isUnsupported(failure)) stopped.current = true;
    setError(isUnsupported(failure) ? SKILLS_UNSUPPORTED : errorText(failure));
  }

  /** `keepError`: a refused action's message stays up while the reload undoes its toggle. */
  async function load(keepError = false): Promise<void> {
    try {
      const value = normalizeSkills(await api<unknown>("/api/v1/skills"));
      if (!alive.current) return;
      show(value);
      if (!keepError) setError("");
    } catch (failure) {
      if (alive.current && !keepError) fail(failure);
    }
  }

  function schedule(delay: number): void {
    clearTimeout(timer.current);
    if (alive.current && !stopped.current) timer.current = setTimeout(() => void tick(), delay);
  }

  async function tick(): Promise<void> {
    if (!working.current) await load();
    schedule(skillsPollDelay(latest.current));
  }

  useEffect(() => {
    void tick();
    return () => clearTimeout(timer.current);
  }, []);

  async function act(body: SkillsAction, name: string): Promise<void> {
    working.current = true;
    setBusy(name);
    try {
      const value = normalizeSkills(await remote.mutate(() => api<unknown>("/api/v1/skills", { method: "POST", body })));
      if (!alive.current) return;
      show(value);
      setError("");
      if (body.action === "sync") {
        const messages = value.messages ?? [];
        setRelinked(messages);
        setAnnouncement(skillsRelinkSummary(messages));
        setTimeout(() => { if (alive.current) setRelinked((shown) => (shown === messages ? null : shown)); }, RELINK_SHOWN_MS);
      }
      schedule(skillsPollDelay(value));
    } catch (failure) {
      if (!alive.current) return;
      fail(failure);
      if (!stopped.current) await load(true);
    } finally {
      working.current = false;
      if (alive.current) setBusy(null);
    }
  }

  function toggle(name: string, enabled: boolean): void {
    if (latest.current) show(skillsWithEnabled(latest.current, name, enabled));
    void act({ action: "setEnabled", name, enabled }, name);
  }

  const value = snapshot;
  return (
    <Sheet title={SKILLS_TITLE} onClose={props.onClose} width={680} height={640} class="skills-sheet">
      <Caption class="sh-intro">{SKILLS_EXPLAINER_LEAD} (<code>{SKILLS_EDIT_COMMAND}</code>).</Caption>
      <div role="alert">{error ? <Warning text={error} /> : null}</div>
      <div class="sr-only" role="status" aria-live="polite">{announcement}</div>
      {!value && !error && <Loading text="Loading skills…" />}
      {value && (
        <>
          <FormSection header="Skills" footer={value.library ? <span class="selectable">Library: {value.library}</span> : undefined}>
            {value.skills.length === 0 && <FormRow><span class="sh-secondary">The library has no skills yet.</span></FormRow>}
            {value.skills.map((skill) => (
              <FormRow key={skill.name} stack class="sk-skill">
                <label class="sk-toggle">
                  <input type="checkbox" role="switch" class="switch" checked={skill.enabled} disabled={busy !== null}
                    aria-label={skillToggleLabel(skill)}
                    onChange={(event) => toggle(skill.name, (event.target as HTMLInputElement).checked)} />
                  <span class="sh-mono sk-name">{skill.name}</span>
                </label>
                {skill.description && <span class="sh-secondary">{skill.description}</span>}
                <span class="sh-caption">{skillSeenBy(skill)}</span>
                {skill.problems.map((problem, index) => <Warning key={index} text={problem} />)}
              </FormRow>
            ))}
          </FormSection>
          <FormSection>
            <FormRow stack>
              <button type="button" class="btn sk-button" disabled={busy !== null}
                aria-describedby="skills-relink-hint" onClick={() => void act({ action: "sync" }, "sync")}>
                <Icon name="link" size={14} /> {busy === "sync" ? "Relinking…" : "Relink"}
              </button>
              <span id="skills-relink-hint" class="sh-caption">Links every skill into every backend again.</span>
              {relinked && (relinked.length === 0
                ? <span class="sh-caption">Everything was already linked.</span>
                : relinked.map((message, index) => <span key={index} class="sh-caption selectable">{message}</span>))}
            </FormRow>
          </FormSection>
          <FormSection header="Folder rules">
            {value.rules.length === 0 && <FormRow><span class="sh-secondary">No folder rules yet.</span></FormRow>}
            {value.rules.map((rule) => <FormRow key={rule.folder}><span class="selectable">{skillsRuleText(rule)}</span></FormRow>)}
          </FormSection>
          <FormSection header="Drift">
            {value.drift.map((finding, index) => (
              <FormRow key={`${finding.path}:${index}`} stack>
                <span class="sh-mono selectable">{finding.path}</span>
                <Warning text={finding.problem} />
              </FormRow>
            ))}
            {skillsDriftClear(value) && (
              <FormRow><span class="sh-label sh-secondary"><Icon name="checkmark.circle" size={14} /> No drift found</span></FormRow>
            )}
            <FormRow stack>
              <span class="sh-caption">{skillsDriftStatus(value, now)}</span>
              <button type="button" class="btn sk-button" disabled={busy !== null || value.checking}
                onClick={() => void act({ action: "check" }, "check")}>
                <Icon name="checklist" size={14} /> Check now
              </button>
            </FormRow>
          </FormSection>
        </>
      )}
    </Sheet>
  );
}
