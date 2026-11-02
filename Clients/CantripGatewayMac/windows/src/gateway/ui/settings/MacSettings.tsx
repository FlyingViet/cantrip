// The Mac's own settings in the Settings window, drawn from its manifest (GET/POST /api/v1/settings,
// SettingsManifest.swift) the way Cantrip Agent draws them: each page's sections at the top of the window's
// page with the same id, changes saved as they're made (typed ones on Enter or on leaving the box), the
// Keep/Undo banner for a change that could cut this PC off, and a reload whenever the Mac's settings move.
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type {
  SettingsActionResult, SettingsField, SettingsManifest, SettingsPage, SettingsRequest, SettingsSection, SettingsValue,
} from "../../api/types";
import { Icon } from "../icons";
import { confirmDialog, FormSection, Spinner } from "../kit";
import {
  actionRequest, changeRequest, choiceToken, coerceValue, fieldDOMID, fieldsByKey, isUnchanged, keepRequest, needsReload,
  numberText, pendingSecondsLeft, pendingText, portText, revertRequest, sameValue, secretStatus, settingsFailure, settingsValues,
  toneClass, unplacedFieldErrors, valueText, visibleFields, visibleSections, type SettingsRevisionInfo,
} from "./macSettingsLogic";

/** How the window reaches GET/POST /api/v1/settings; failures carry the HTTP `status` and JSON `body` (APIError). */
export interface MacSettingsTransport {
  load(): Promise<SettingsManifest>;
  send(body: SettingsRequest): Promise<SettingsManifest>;
  openLink(url: string): void;
}

export type MacSettingsPhase = "idle" | "loading" | "ready" | "unsupported" | "error";

export interface MacSettingsModel {
  phase: MacSettingsPhase;
  /** Null until loaded, and on Macs without the manifest. */
  manifest: SettingsManifest | null;
  /** When `manifest` arrived (its `pending.secondsLeft` counts from then). */
  receivedAt: number;
  /** Every field's value, with changes on their way on top. */
  values: ReadonlyMap<string, SettingsValue>;
  /** Fields (and `pending:<id>`) waiting for the Mac. */
  busy: ReadonlySet<string>;
  fieldErrors: Readonly<Record<string, string>>;
  results: Readonly<Record<string, SettingsActionResult>>;
  notice: string | null;
  loadError: string | null;
  save(field: SettingsField, input: unknown): Promise<boolean>;
  run(field: SettingsField): Promise<void>;
  answer(kind: "keep" | "revert"): void;
  reload(): void;
  dismissResult(key: string): void;
  dismissNotice(): void;
  /** Escape in a refused box: its reason goes with the typed value. */
  clearError(key: string): void;
  openLink(url: string): void;
}

/**
 * The Mac's settings for the selected Mac (`server`): loaded once, then again when the polled revision
 * moves past the shown one or the window comes back to the front (a box being typed in keeps its text,
 * see useTypedText). Requests run one at a time, so each change goes with the revision the one before it
 * returned.
 */
export function useMacSettings(
  transport: MacSettingsTransport,
  options: { server: string | null; polled: SettingsRevisionInfo | null; connected: boolean },
): MacSettingsModel {
  const [manifest, setManifest] = useState<SettingsManifest | null>(null);
  const [phase, setPhase] = useState<MacSettingsPhase>("idle");
  const [receivedAt, setReceivedAt] = useState(0);
  const [drafts, setDrafts] = useState<Record<string, SettingsValue>>({});
  const [busy, setBusy] = useState<ReadonlySet<string>>(new Set());
  const [fieldErrors, setFieldErrors] = useState<Record<string, string>>({});
  const [results, setResults] = useState<Record<string, SettingsActionResult>>({});
  const [notice, setNotice] = useState<string | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const latest = useRef<SettingsManifest | null>(null);
  const draftsRef = useRef<Record<string, { value: SettingsValue; serial: number }>>({});
  const serial = useRef(0);
  const queue = useRef<Promise<unknown>>(Promise.resolve());
  const generation = useRef(0);
  const unsupported = options.polled !== null && !options.polled.supportsSettings;

  function show(next: SettingsManifest): void {
    latest.current = next;
    setManifest(next);
    setReceivedAt(Date.now());
    setPhase("ready");
    setLoadError(null);
  }

  function hide(next: MacSettingsPhase): void {
    latest.current = null;
    setManifest(null);
    setPhase(next);
  }

  function mark(key: string, on: boolean): void {
    setBusy((current) => {
      const next = new Set(current);
      if (on) next.add(key); else next.delete(key);
      return next;
    });
  }

  function setErrors(change: Record<string, string | null>): void {
    setFieldErrors((current) => {
      const next = { ...current };
      for (const [key, reason] of Object.entries(change)) {
        if (reason === null) delete next[key]; else next[key] = reason;
      }
      return next;
    });
  }

  function setDraft(key: string, value: SettingsValue | null, only?: number): number {
    const current = draftsRef.current[key];
    if (value === null) {
      if (only !== undefined && current?.serial !== only) return current?.serial ?? 0;
      delete draftsRef.current[key];
    } else {
      draftsRef.current[key] = { value, serial: ++serial.current };
    }
    setDrafts(Object.fromEntries(Object.entries(draftsRef.current).map(([name, draft]) => [name, draft.value])));
    return draftsRef.current[key]?.serial ?? 0;
  }

  /** Runs `work` after the requests before it, unless the window switched Macs meanwhile. */
  function enqueue<T>(work: (current: () => boolean) => Promise<T>): Promise<T | undefined> {
    const mine = generation.current;
    const current = () => mine === generation.current;
    const run = queue.current.then(() => (current() ? work(current) : undefined));
    queue.current = run.catch(() => undefined);
    return run;
  }

  function fail(error: unknown, keys: string[]): void {
    const failure = settingsFailure(error);
    if (failure.kind === "unsupported") {
      hide("unsupported");
    } else if (failure.kind === "stale") {
      if (failure.manifest) show(failure.manifest);
      setNotice(failure.message);
    } else if (failure.kind === "invalid") {
      const fields = Object.keys(failure.fields).length ? failure.fields : Object.fromEntries(keys.map((key) => [key, failure.message]));
      setErrors(fields);
      const shown = latest.current ? new Set(fieldsByKey(latest.current).keys()) : new Set<string>();
      const lost = unplacedFieldErrors(fields, shown);
      if (lost.length) setNotice(lost.join(" "));
    } else if (keys.length) {
      setErrors(Object.fromEntries(keys.map((key) => [key, failure.message])));
    } else {
      setNotice(failure.message);
    }
  }

  function load(): Promise<unknown> {
    if (!latest.current) setPhase("loading");
    return enqueue(async (current) => {
      try {
        const next = await transport.load();
        if (current()) show(next);
      } catch (error) {
        if (!current()) return;
        const failure = settingsFailure(error);
        if (failure.kind === "unsupported") hide("unsupported");
        else if (!latest.current) {
          setPhase("error");
          setLoadError(failure.message);
        }
      }
    });
  }

  function reload(): void {
    void load();
  }

  // A new Mac (or one that turns out not to have the manifest): start over.
  useEffect(() => {
    generation.current++;
    queue.current = Promise.resolve();
    draftsRef.current = {};
    latest.current = null;
    setManifest(null);
    setDrafts({});
    setBusy(new Set());
    setFieldErrors({});
    setResults({});
    setNotice(null);
    setLoadError(null);
    if (!options.server || unsupported) {
      setPhase(unsupported ? "unsupported" : "idle");
      return;
    }
    void load();
  }, [options.server, unsupported]);

  // Another device (or the Mac) changed a setting.
  useEffect(() => {
    if (needsReload(latest.current?.revision, options.polled)) reload();
  }, [options.polled?.settingsRevision]);

  // Back in touch after a failed first load.
  useEffect(() => {
    if (options.connected && options.server && !unsupported && !latest.current && phase === "error") void load();
  }, [options.connected]);

  // Back to the front: the main window polls slowly behind other windows (and not at all while minimized).
  useEffect(() => {
    const focus = () => { if (latest.current) reload(); };
    addEventListener("focus", focus);
    return () => removeEventListener("focus", focus);
  }, []);

  async function save(field: SettingsField, input: unknown): Promise<boolean> {
    const coerced = coerceValue(field, input);
    if ("error" in coerced) {
      setErrors({ [field.key]: coerced.error });
      return false;
    }
    const { value } = coerced;
    const shownField = (latest.current && fieldsByKey(latest.current).get(field.key)) || field;
    const current = draftsRef.current[field.key]?.value ?? shownField.value;
    if (field.type === "secret" ? isUnchanged(shownField, value) : sameValue(current, value)) {
      setErrors({ [field.key]: null });
      return true;
    }
    const mine = setDraft(field.key, value);
    setErrors({ [field.key]: null });
    mark(field.key, true);
    const saved = await enqueue(async (isCurrent) => {
      try {
        const shown = latest.current;
        if (!shown) return false;
        const next = await transport.send(changeRequest(shown.revision, { [field.key]: value }));
        if (isCurrent()) {
          show(next);
          setNotice(null);
        }
        return true;
      } catch (error) {
        if (isCurrent()) fail(error, [field.key]);
        return false;
      } finally {
        if (isCurrent()) {
          setDraft(field.key, null, mine);
          mark(field.key, false);
        }
      }
    });
    return saved === true;
  }

  async function run(field: SettingsField): Promise<void> {
    if (field.readOnly || busy.has(field.key)) return;
    if (field.confirmation) {
      const ok = await confirmDialog({
        title: `${field.label}?`, message: field.confirmation, confirm: field.label, destructive: field.destructive === true,
      });
      if (!ok) return;
    }
    setErrors({ [field.key]: null });
    setResults((shown) => {
      const next = { ...shown };
      delete next[field.key];
      return next;
    });
    mark(field.key, true);
    await enqueue(async (isCurrent) => {
      try {
        const next = await transport.send(actionRequest(field.key));
        if (!isCurrent()) return;
        show(next);
        setNotice(null);
        const result = next.result;
        if (result && (result.message || result.copy || result.link)) setResults((shown) => ({ ...shown, [field.key]: result }));
      } catch (error) {
        if (isCurrent()) fail(error, [field.key]);
      } finally {
        if (isCurrent()) mark(field.key, false);
      }
    });
  }

  function answer(kind: "keep" | "revert"): void {
    const pending = latest.current?.pending;
    if (!pending) return;
    const key = `pending:${pending.id}`;
    mark(key, true);
    setNotice(null);
    void enqueue(async (isCurrent) => {
      try {
        const next = await transport.send(kind === "keep" ? keepRequest(pending) : revertRequest(pending));
        if (isCurrent()) show(next);
      } catch (error) {
        if (isCurrent()) fail(error, []);
      } finally {
        if (isCurrent()) mark(key, false);
      }
    });
  }

  return {
    phase: manifest ? "ready" : phase,
    manifest,
    receivedAt,
    values: manifest ? settingsValues(manifest, drafts) : new Map(),
    busy,
    fieldErrors,
    results,
    notice,
    loadError,
    save,
    run,
    answer,
    reload,
    dismissResult: (key) => setResults((shown) => {
      const next = { ...shown };
      delete next[key];
      return next;
    }),
    dismissNotice: () => setNotice(null),
    clearError: (key) => setErrors({ [key]: null }),
    openLink: (url) => transport.openLink(url),
  };
}

// MARK: Banner (every page)

/** A guarded change waiting to be kept (with a countdown to the Mac undoing it), and the last refusal. */
export function MacSettingsBanner(props: { model: MacSettingsModel; showLoadError?: boolean }): JSX.Element | null {
  const { model } = props;
  const pending = model.manifest?.pending;
  const [now, setNow] = useState(Date.now());
  useEffect(() => {
    if (!pending) return;
    setNow(Date.now());
    const timer = setInterval(() => setNow(Date.now()), 1000);
    return () => clearInterval(timer);
  }, [pending?.id, model.receivedAt]);
  const seconds = pending ? pendingSecondsLeft(pending, model.receivedAt, now) : null;
  // The Mac undoes it at zero: show what it went back to.
  useEffect(() => {
    if (seconds !== 0) return;
    const timer = setTimeout(() => model.reload(), 1500);
    return () => clearTimeout(timer);
  }, [seconds === 0, pending?.id]);
  const answering = pending ? model.busy.has(`pending:${pending.id}`) : false;
  const loadError = props.showLoadError && model.phase === "error";
  if (!pending && !model.notice && !loadError) return null;
  return (
    <div class="mac-banners">
      {pending ? (
        <div class="mac-pending" role="group" aria-label={`Keep ${pending.summary}?`}>
          <Icon name="clock" class="orange" />
          <span class="grow" aria-hidden="true">{pendingText(pending, seconds ?? 0)}</span>
          <span class="sr-only" role="status">{`Keep ${pending.summary}? The Mac undoes it in ${pending.secondsLeft} seconds unless you keep it.`}</span>
          {answering ? <Spinner size="small" label="Waiting for the Mac" /> : null}
          <button type="button" class="btn primary small" disabled={answering} onClick={() => model.answer("keep")}>Keep</button>
          <button type="button" class="btn small" disabled={answering} onClick={() => model.answer("revert")}>Undo</button>
        </div>
      ) : null}
      {model.notice ? (
        <div class="mac-notice alert-text" role="alert">
          <Icon name="exclamationmark.triangle" size={14} />
          <span class="grow">{model.notice}</span>
          <button type="button" class="icon-btn small" aria-label="Dismiss" onClick={() => model.dismissNotice()}><Icon name="xmark" size={12} /></button>
        </div>
      ) : null}
      {loadError ? (
        <div class="mac-notice alert-text" role="alert">
          <Icon name="exclamationmark.triangle" size={14} />
          <span class="grow">Couldn't load the Mac's settings{model.loadError ? `: ${model.loadError}` : "."}</span>
          <button type="button" class="btn small" onClick={() => model.reload()}>Try Again</button>
        </div>
      ) : null}
    </div>
  );
}

// MARK: A page's sections

/** The Mac's sections for one page; consecutive `link` sections share one group of rows that open. */
export function MacSettingsPage(props: { model: MacSettingsModel; page: SettingsPage }): JSX.Element | null {
  const { model, page } = props;
  const sections = visibleSections(page, model.values);
  if (!sections.length) return null;
  const groups: (SettingsSection | SettingsSection[])[] = [];
  for (const section of sections) {
    const last = groups[groups.length - 1];
    if (section.link && Array.isArray(last)) last.push(section);
    else groups.push(section.link ? [section] : section);
  }
  return (
    <div class="mac-settings" role="region" aria-label={`${page.title} on ${model.manifest?.mac || "the Mac"}`}>
      {groups.map((group) => Array.isArray(group) ? (
        <FormSection key={group.map((section) => section.id).join()} class="mac-links">
          {group.map((section) => <LinkSection key={section.id} section={section} model={model} />)}
        </FormSection>
      ) : (
        <FormSection key={group.id} header={group.title || undefined} footer={group.footer}>
          {visibleFields(group, model.values).map((field) => <FieldRow key={field.key} field={field} model={model} />)}
        </FormSection>
      ))}
    </div>
  );
}

/** A section that opens in place: its title and `summary` while closed, its fields while open. */
function LinkSection(props: { section: SettingsSection; model: MacSettingsModel }): JSX.Element {
  const { section, model } = props;
  const [open, setOpen] = useState(false);
  const id = `mac-section-${section.id.replace(/[^A-Za-z0-9_-]/g, "-")}`;
  return (
    <div class="mac-link">
      <button type="button" class="form-row mac-link-row" aria-expanded={open ? "true" : "false"} aria-controls={id} onClick={() => setOpen(!open)}>
        <span class="grow">{section.title}</span>
        {!open && section.summary ? <span class="form-value truncate mac-summary">{section.summary}</span> : null}
        <Icon name={open ? "chevron.down" : "chevron.right"} size={14} class="muted" />
      </button>
      {open ? (
        <div id={id} class="mac-link-body" role="group" aria-label={section.title}>
          {visibleFields(section, model.values).map((field) => <FieldRow key={field.key} field={field} model={model} />)}
          {section.footer ? <div class="form-row caption muted">{section.footer}</div> : null}
        </div>
      ) : null}
    </div>
  );
}

// MARK: Fields

interface ControlProps {
  field: SettingsField;
  model: MacSettingsModel;
  value: SettingsValue | undefined;
  id: string;
  describedBy?: string;
  busy: boolean;
}

function FieldRow(props: { field: SettingsField; model: MacSettingsModel }): JSX.Element {
  const { field, model } = props;
  const id = fieldDOMID(field.key);
  const value = model.values.get(field.key);
  const busy = model.busy.has(field.key);
  const error = model.fieldErrors[field.key];
  const result = model.results[field.key];
  const reason = field.readOnly ? field.readOnlyReason : undefined;
  const describedBy = [field.help && `${id}-help`, reason && `${id}-reason`, error && `${id}-error`].filter(Boolean).join(" ") || undefined;
  const control: ControlProps = { field, model, value, id, describedBy, busy };
  const spinner = busy ? <Spinner size="small" label={field.type === "action" ? `${field.label}…` : `Saving ${field.label}`} /> : null;
  const label = <label class="grow mac-label" for={id}>{field.label}</label>;
  let line: JSX.Element;
  switch (field.type) {
    case "toggle":
      line = <div class="row mac-line">{label}{spinner}<ToggleControl {...control} /></div>;
      break;
    case "choice":
      line = <div class="row mac-line">{label}{spinner}<ChoiceControl {...control} /></div>;
      break;
    case "integer":
      line = <div class="row mac-line">{label}{spinner}<IntegerControl {...control} /></div>;
      break;
    case "port":
      line = <div class="row mac-line">{label}{spinner}<PortControl {...control} /></div>;
      break;
    case "number":
      line = <div class="row mac-line">{label}{spinner}<NumberControl {...control} /></div>;
      break;
    case "text":
    case "path":
      line = field.multiline
        ? <><div class="row mac-line">{label}{spinner}</div><TextControl {...control} /></>
        : <div class="row mac-line">{label}{spinner}<TextControl {...control} /></div>;
      break;
    case "secret":
      line = (
        <>
          <div class="row mac-line">
            {label}{spinner}
            <span class={`chip${field.isSet ? " green" : ""}`}>{secretStatus(field)}</span>
          </div>
          <SecretControl {...control} />
        </>
      );
      break;
    case "action":
      line = (
        <div class="row mac-line">
          <button id={id} type="button" class={`btn${field.destructive ? " destructive" : ""}`} disabled={field.readOnly || busy}
            aria-describedby={describedBy} onClick={() => void model.run(field)}>{field.label}</button>
          {spinner}
        </div>
      );
      break;
    default:
      line = (
        <div class="row mac-line">
          <span class="grow mac-label" id={id}>{field.label}</span>
          <span class={`selectable mac-info ${toneClass(field.tone)}`} aria-labelledby={id}>{valueText(value)}</span>
        </div>
      );
  }
  return (
    <div class={`form-row stack mac-field${field.readOnly ? " read-only" : ""}`} data-setting={field.key}>
      {line}
      {field.help ? <div id={`${id}-help`} class="caption muted mac-help">{field.help}</div> : null}
      {reason ? <div id={`${id}-reason`} class="caption muted row mac-reason"><Icon name="lock.fill" size={12} />{reason}</div> : null}
      {error ? <div id={`${id}-error`} class="alert-text" role="alert"><Icon name="exclamationmark.triangle" size={14} />{error}</div> : null}
      {result ? <ActionResult result={result} onOpen={(url) => model.openLink(url)} onDone={() => model.dismissResult(field.key)} /> : null}
    </div>
  );
}

function ToggleControl(props: ControlProps): JSX.Element {
  const { field, model } = props;
  return (
    <input id={props.id} type="checkbox" class="switch" role="switch" checked={props.value === true} disabled={field.readOnly}
      aria-describedby={props.describedBy} aria-busy={props.busy}
      onChange={(event) => void model.save(field, (event.currentTarget as HTMLInputElement).checked)} />
  );
}

function ChoiceControl(props: ControlProps): JSX.Element {
  const { field, model, value } = props;
  const choices = field.choices ?? [];
  const token = choiceToken(value);
  const known = choices.some((choice) => choiceToken(choice.value) === token);
  return (
    <select id={props.id} class="select mac-select" value={token} disabled={field.readOnly} aria-describedby={props.describedBy}
      onChange={(event) => void model.save(field, (event.currentTarget as HTMLSelectElement).value)}>
      {!known ? <option value={token} disabled>{value === undefined ? "Choose…" : valueText(value)}</option> : null}
      {choices.map((choice) => (
        <option key={choiceToken(choice.value)} value={choiceToken(choice.value)} disabled={choice.disabled}>{choice.label}</option>
      ))}
    </select>
  );
}

interface TypedText {
  text: string;
  /** The box's own input. */
  type(text: string): void;
  /** Escape: back to the saved value. */
  revert(): void;
  /** Enter or leaving the box: sends what's in it (read from the box itself) when it differs from the saved value; a refused value stays to be fixed. */
  commit(input: string): void;
  ref: { current: HTMLElement | null };
}

/**
 * Text typed into a setting stays on this PC until Enter or leaving the box. A reload replaces it
 * unless it's being edited (typed in, or refused and not fixed yet), so another device's change never
 * clobbers typing and an untouched box never sends back an old value.
 */
function useTypedText(saved: string, send: (input: string) => Promise<boolean>, same: (input: string) => boolean): TypedText {
  const [text, setText] = useState(saved);
  const ref = useRef<HTMLElement | null>(null);
  const edited = useRef(false);
  useEffect(() => {
    if (edited.current) return;
    setText(saved);
  }, [saved]);
  return {
    text,
    ref,
    type: (input) => { edited.current = true; setText(input); },
    revert: () => { edited.current = false; setText(saved); },
    commit: (input) => {
      edited.current = false;
      setText(input);
      if (same(input)) return;
      void send(input).then((saved) => {
        if (saved) return;
        edited.current = true;
        setText(input);
      });
    },
  };
}

function IntegerControl(props: ControlProps): JSX.Element {
  const { field, model, value } = props;
  const saved = typeof value === "number" ? String(value) : "";
  const box = useTypedText(saved, (input) => model.save(field, input), (input) => input.trim() === saved);
  const input = (event: Event) => (event.currentTarget as HTMLInputElement).value;
  return (
    <span class="row mac-integer">
      <input id={props.id} ref={box.ref as { current: HTMLInputElement | null }} type="number" inputMode="numeric" class="text-field mac-number"
        value={box.text} min={field.min} max={field.max} step={field.step ?? 1} disabled={field.readOnly} aria-describedby={props.describedBy}
        onInput={(event) => box.type(input(event))}
        onChange={(event) => box.commit(input(event))}
        onKeyDown={(event) => {
          if (event.key === "Enter") { event.preventDefault(); box.commit(input(event)); }
          else if (event.key === "Escape" && box.text !== saved) { event.preventDefault(); box.revert(); model.clearError(field.key); }
        }} />
      {field.unit ? <span class="muted callout">{field.unit}</span> : null}
    </span>
  );
}

function PortControl(props: ControlProps): JSX.Element {
  const { field, model, value } = props;
  const saved = portText(field, value);
  const box = useTypedText(saved, (input) => model.save(field, input), (input) => input.trim() === saved);
  const input = (event: Event) => (event.currentTarget as HTMLInputElement).value;
  return (
    <input id={props.id} ref={box.ref as { current: HTMLInputElement | null }} type="text" inputMode="numeric" autocomplete="off" spellcheck={false}
      class="text-field mac-port" value={box.text} maxLength={5} placeholder={field.zeroLabel ?? field.placeholder}
      disabled={field.readOnly} aria-describedby={props.describedBy}
      onInput={(event) => box.type(input(event))}
      onBlur={(event) => box.commit(input(event))}
      onKeyDown={(event) => {
        if (event.key === "Enter") { event.preventDefault(); box.commit(input(event)); }
        else if (event.key === "Escape" && box.text !== saved) { event.preventDefault(); box.revert(); model.clearError(field.key); }
      }} />
  );
}

function NumberControl(props: ControlProps): JSX.Element {
  const { field, model, value } = props;
  const [dragging, setDragging] = useState<number | null>(null);
  const shown = dragging ?? (typeof value === "number" ? value : field.min ?? 0);
  return (
    <span class="row mac-slider">
      <input id={props.id} type="range" class="mac-range" min={field.min ?? 0} max={field.max ?? 1} step={field.step ?? "any"} value={shown}
        disabled={field.readOnly} aria-describedby={props.describedBy} aria-valuetext={numberText(field, shown)}
        onInput={(event) => setDragging(Number((event.currentTarget as HTMLInputElement).value))}
        onChange={(event) => {
          void model.save(field, Number((event.currentTarget as HTMLInputElement).value));
          setDragging(null);
        }} />
      <output for={props.id} class="mac-range-value callout">{numberText(field, shown)}</output>
    </span>
  );
}

function TextControl(props: ControlProps): JSX.Element {
  const { field, model, value } = props;
  const saved = typeof value === "string" ? value : "";
  const box = useTypedText(saved, (input) => model.save(field, input), (input) => input === saved);
  const input = (event: Event) => (event.currentTarget as HTMLInputElement | HTMLTextAreaElement).value;
  const revert = (event: KeyboardEvent) => {
    if (event.key === "Escape" && box.text !== saved) { event.preventDefault(); box.revert(); model.clearError(field.key); }
  };
  const shared = {
    id: props.id, value: box.text, maxLength: field.maxLength, placeholder: field.placeholder, disabled: field.readOnly,
    spellcheck: false, autocomplete: "off", "aria-describedby": props.describedBy,
    onInput: (event: Event) => box.type(input(event)),
    onBlur: (event: Event) => box.commit(input(event)),
  };
  return field.multiline ? (
    <textarea {...shared} ref={box.ref as { current: HTMLTextAreaElement | null }} class="text-field mac-textarea" rows={4}
      onKeyDown={(event) => {
        if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); box.commit(input(event)); } else revert(event);
      }} />
  ) : (
    <input {...shared} ref={box.ref as { current: HTMLInputElement | null }} type="text" class={`text-field mac-text${field.type === "path" ? " mono" : ""}`}
      onKeyDown={(event) => {
        if (event.key === "Enter") { event.preventDefault(); box.commit(input(event)); } else revert(event);
      }} />
  );
}

function SecretControl(props: ControlProps): JSX.Element {
  const { field, model } = props;
  const [text, setText] = useState("");
  const ref = useRef<HTMLInputElement>(null);
  const save = async () => {
    const typed = ref.current?.value ?? text;
    if (typed && await model.save(field, typed)) setText("");
  };
  return (
    <div class="row mac-secret">
      <input id={props.id} ref={ref} type="password" class="text-field grow" value={text} maxLength={field.maxLength} autocomplete="new-password"
        spellcheck={false} placeholder={field.isSet ? "Enter a new one to replace it" : field.placeholder ?? ""} disabled={field.readOnly}
        aria-describedby={props.describedBy}
        onInput={(event) => setText((event.currentTarget as HTMLInputElement).value)}
        onKeyDown={(event) => { if (event.key === "Enter") { event.preventDefault(); void save(); } }} />
      <button type="button" class="btn" disabled={!text || field.readOnly || props.busy} onClick={() => void save()}
        aria-label={`Save ${field.label}`}>Save</button>
      <button type="button" class="btn destructive" disabled={!field.isSet || field.readOnly || props.busy}
        aria-label={`Clear ${field.label}`} onClick={() => void model.save(field, "")}>Clear</button>
    </div>
  );
}

/** What a button did: its message, text to copy (shown this once), or a link. */
export function ActionResult(props: { result: SettingsActionResult; onOpen: (url: string) => void; onDone: () => void }): JSX.Element {
  const { result } = props;
  const [copied, setCopied] = useState<string | null>(null);
  const copy = async (text: string) => {
    try {
      await navigator.clipboard.writeText(text);
      setCopied("Copied.");
    } catch {
      setCopied("Couldn't copy: select it and press Ctrl+C.");
    }
  };
  const web = result.link !== undefined && /^https?:\/\//i.test(result.link);
  return (
    <div class="mac-result" role="status">
      <div class="row">
        <span class="grow col">
          {result.title ? <span class="headline">{result.title}</span> : null}
          {result.message ? <span class="callout">{result.message}</span> : null}
        </span>
        <button type="button" class="icon-btn" aria-label="Dismiss" title="Dismiss" onClick={props.onDone}><Icon name="xmark" size={14} /></button>
      </div>
      {result.copy ? (
        <div class="row">
          <code class="mono selectable grow mac-copy">{result.copy}</code>
          <button type="button" class="btn small" onClick={() => void copy(result.copy!)}>Copy</button>
        </div>
      ) : null}
      {result.link ? (
        <div class="row">
          {web
            ? <a class="selectable grow mac-copy" href={result.link} onClick={(event) => { event.preventDefault(); props.onOpen(result.link!); }}>{result.link}</a>
            : <code class="mono selectable grow mac-copy">{result.link}</code>}
          <button type="button" class="btn small" onClick={() => void copy(result.link!)}>Copy</button>
        </div>
      ) : null}
      {copied ? <span class="caption muted" aria-live="polite">{copied}</span> : null}
    </div>
  );
}
