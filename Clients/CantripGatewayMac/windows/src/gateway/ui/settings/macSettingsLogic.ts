// The Mac's settings manifest (GET/POST /api/v1/settings, SettingsManifest.swift) as pure rules: which
// fields show, what a control's input becomes on the wire, the request bodies, and what a refused save
// means. The Settings window draws every page from these (MacSettings.tsx). No DOM or API client
// imports, so it runs under Node.
import type {
  SettingsActionRequest, SettingsChangeRequest, SettingsField, SettingsFieldType, SettingsKeepRequest, SettingsManifest,
  SettingsPage, SettingsPending, SettingsRevertRequest, SettingsSection, SettingsValue,
} from "../../api/types";
import { graphemeCount } from "../sheets/sheetLogic";

const FIELD_TYPES = new Set<SettingsFieldType>(["toggle", "choice", "integer", "port", "number", "text", "path", "secret", "action", "info"]);

function isValue(value: unknown): value is SettingsValue {
  return typeof value === "boolean" || typeof value === "string" || (typeof value === "number" && Number.isFinite(value));
}

/** The manifest without anything this client can't draw (unknown field types, malformed rows), or null. */
export function normalizeManifest(raw: unknown): SettingsManifest | null {
  if (!raw || typeof raw !== "object") return null;
  const value = raw as Partial<SettingsManifest>;
  if (typeof value.revision !== "string" || !Array.isArray(value.pages)) return null;
  const pages: SettingsPage[] = [];
  for (const page of value.pages) {
    if (!page || typeof page.id !== "string" || !Array.isArray(page.sections)) continue;
    const sections: SettingsSection[] = [];
    for (const section of page.sections) {
      if (!section || typeof section.id !== "string" || !Array.isArray(section.fields)) continue;
      const fields = section.fields.filter((field): field is SettingsField =>
        Boolean(field) && typeof field.key === "string" && typeof field.label === "string" && FIELD_TYPES.has(field.type)
        && (field.value === undefined || isValue(field.value)));
      if (fields.length) sections.push({ ...section, title: String(section.title ?? ""), fields });
    }
    if (sections.length) pages.push({ id: page.id, title: String(page.title ?? page.id), sections });
  }
  const pending = value.pending;
  return {
    version: typeof value.version === "number" ? value.version : 1,
    revision: value.revision,
    mac: typeof value.mac === "string" ? value.mac : "",
    local: value.local === true,
    pages,
    pending: pending && typeof pending.id === "string" && typeof pending.secondsLeft === "number" ? pending : undefined,
    result: value.result && typeof value.result === "object" ? value.result : undefined,
  };
}

// MARK: Values and visibility

/** Every field by key; the first one wins, as the Mac's own lookup does. */
export function fieldsByKey(manifest: SettingsManifest): Map<string, SettingsField> {
  const fields = new Map<string, SettingsField>();
  for (const page of manifest.pages) {
    for (const section of page.sections) {
      for (const field of section.fields) if (!fields.has(field.key)) fields.set(field.key, field);
    }
  }
  return fields;
}

/** Each field's current value by key, with `drafts` (changes on their way to the Mac) on top. */
export function settingsValues(manifest: SettingsManifest, drafts: Readonly<Record<string, SettingsValue>> = {}): Map<string, SettingsValue> {
  const values = new Map<string, SettingsValue>();
  for (const [key, field] of fieldsByKey(manifest)) if (field.value !== undefined) values.set(key, field.value);
  for (const [key, value] of Object.entries(drafts)) values.set(key, value);
  return values;
}

/** JSON equality for setting values: `true` isn't 1 and "1" isn't 1, but 1 is 1.0. */
export function sameValue(a: SettingsValue | undefined, b: SettingsValue | undefined): boolean {
  return a !== undefined && b !== undefined && typeof a === typeof b && a === b;
}

/** `visibleWhen`: shown only while that field (on any page) has one of the listed values; hidden while it has none. */
export function isFieldVisible(field: SettingsField, values: ReadonlyMap<string, SettingsValue>): boolean {
  const rule = field.visibleWhen;
  if (!rule) return true;
  const current = values.get(rule.key);
  return Array.isArray(rule.values) && rule.values.some((value) => sameValue(value, current));
}

export function visibleFields(section: SettingsSection, values: ReadonlyMap<string, SettingsValue>): SettingsField[] {
  return section.fields.filter((field) => isFieldVisible(field, values));
}

/** A page's sections that have something to show. */
export function visibleSections(page: SettingsPage, values: ReadonlyMap<string, SettingsValue>): SettingsSection[] {
  return page.sections.filter((section) => visibleFields(section, values).length > 0);
}

// MARK: Pages

/** iPhone's Settings page order; the window's own pages (Connection = `macs`, Voice, Location) sit among them. */
export const SETTINGS_PAGE_ORDER = ["macs", "models", "tools", "home", "memory", "voice", "location", "notifications", "appearance", "about"];

export interface SettingsTab {
  id: string;
  title: string;
  /** The Mac's sections for this page, drawn at its top. */
  page?: SettingsPage;
  /** One of the window's own pages (it has more than the Mac's sections). */
  own: boolean;
}

/**
 * The window's pages and the Mac's, merged by id in iPhone's order: the Mac's sections go at the top of
 * the page with the same id; pages only the Mac has become pages of their own (unknown ids last).
 */
export function settingsTabs(own: ReadonlyArray<{ id: string; title: string }>, pages: readonly SettingsPage[]): SettingsTab[] {
  const tabs: SettingsTab[] = own.map((item) => ({ ...item, own: true, page: pages.find((page) => page.id === item.id) }));
  for (const page of pages) {
    if (!tabs.some((tab) => tab.id === page.id)) tabs.push({ id: page.id, title: page.title, page, own: false });
  }
  const rank = (id: string) => {
    const index = SETTINGS_PAGE_ORDER.indexOf(id);
    return index < 0 ? SETTINGS_PAGE_ORDER.length : index;
  };
  return tabs.map((tab, index) => ({ tab, index }))
    .sort((a, b) => rank(a.tab.id) - rank(b.tab.id) || a.index - b.index)
    .map(({ tab }) => tab);
}

// MARK: Controls → values

export type Coerced = { value: SettingsValue } | { error: string };

/** A `<select>` option's value for a choice: its JSON, so a number comes back a number. */
export function choiceToken(value: SettingsValue | undefined): string {
  return value === undefined ? "" : JSON.stringify(value);
}

/** What a control's input sends, checked the way the Mac checks it (SettingsManifest.check). */
export function coerceValue(field: SettingsField, input: unknown): Coerced {
  if (field.readOnly) return { error: field.readOnlyReason ?? `${field.label} can't be changed here.` };
  switch (field.type) {
    case "toggle":
      return typeof input === "boolean" ? { value: input } : { error: `${field.label} is on or off.` };
    case "choice": {
      const token = typeof input === "string" ? input : isValue(input) ? choiceToken(input) : "";
      const choice = (field.choices ?? []).find((item) => choiceToken(item.value) === token);
      return choice && !choice.disabled ? { value: choice.value } : { error: `Choose one of ${field.label}'s options.` };
    }
    case "integer":
    case "port": {
      const text = typeof input === "number" ? String(input) : typeof input === "string" ? input.trim() : "";
      const zero = field.zeroLabel !== undefined;
      if (!text && zero) return { value: 0 };
      if (!/^[+-]?\d+$/.test(text) || !Number.isSafeInteger(Number(text))) return { error: `${field.label} is a whole number.` };
      const number = Number(text);
      const low = field.min ?? 0;
      const high = field.max ?? Number.MAX_SAFE_INTEGER;
      if ((number < low || number > high) && !(number === 0 && zero)) {
        return field.type === "port" && zero
          ? { error: `${field.label} is ${Math.max(low, 1)}–${high}, or empty for ${field.zeroLabel!.toLowerCase()}.` }
          : { error: `${field.label} is ${low}–${high}.` };
      }
      return { value: number };
    }
    case "number": {
      const number = typeof input === "number" ? input : typeof input === "string" && input.trim() ? Number(input) : Number.NaN;
      if (!Number.isFinite(number)) return { error: `${field.label} is a number.` };
      if ((field.min !== undefined && number < field.min) || (field.max !== undefined && number > field.max)) {
        return { error: `${field.label} is out of range.` };
      }
      return { value: number };
    }
    case "text":
    case "path":
    case "secret": {
      if (typeof input !== "string") return { error: `${field.label} is text.` };
      if (field.maxLength !== undefined && graphemeCount(input) > field.maxLength) return { error: `${field.label} is too long.` };
      if ((field.type !== "text" || !field.multiline) && /[\r\n]/.test(input)) return { error: `${field.label} is one line.` };
      return { value: field.type === "path" ? input.trim() : input };
    }
    default:
      return { error: `${field.label} can't be set.` };
  }
}

/** Whether sending `value` would change nothing: a secret's "" when none is set, or any other field's current value. */
export function isUnchanged(field: SettingsField, value: SettingsValue): boolean {
  if (field.type === "secret") return value === "" && field.isSet !== true;
  return sameValue(field.value, value);
}

// MARK: Requests

export function changeRequest(revision: string, changes: Readonly<Record<string, SettingsValue>>): SettingsChangeRequest {
  return { revision, changes: { ...changes } };
}

export function actionRequest(key: string): SettingsActionRequest {
  return { action: key };
}

export function keepRequest(pending: Pick<SettingsPending, "id">): SettingsKeepRequest {
  return { keep: pending.id };
}

export function revertRequest(pending: Pick<SettingsPending, "id">): SettingsRevertRequest {
  return { revert: pending.id };
}

// MARK: Refusals

export type SettingsFailure =
  /** 404: a Mac from before the manifest. */
  | { kind: "unsupported" }
  /** 409: changed elsewhere, or a guarded change is already waiting; `manifest` is the Mac's current one. */
  | { kind: "stale"; message: string; manifest: SettingsManifest | null }
  /** 422: nothing was saved; `fields` says why for each refused key. */
  | { kind: "invalid"; message: string; fields: Record<string, string> }
  | { kind: "failed"; message: string };

/** What a refused request means, from its HTTP status and JSON body (`APIError.status` and `.body`). */
export function settingsFailure(error: unknown): SettingsFailure {
  const status = (error as { status?: unknown } | null)?.status;
  const body = (error as { body?: unknown } | null)?.body as { settings?: unknown; fields?: unknown } | null | undefined;
  const message = error instanceof Error ? error.message : String(error);
  if (status === 404) return { kind: "unsupported" };
  if (status === 409) return { kind: "stale", message, manifest: normalizeManifest(body?.settings) };
  if (status === 422) {
    const fields: Record<string, string> = {};
    if (body?.fields && typeof body.fields === "object") {
      for (const [key, reason] of Object.entries(body.fields as Record<string, unknown>)) {
        if (typeof reason === "string") fields[key] = reason;
      }
    }
    return { kind: "invalid", message, fields };
  }
  return { kind: "failed", message };
}

/** 422 reasons for keys no visible field can show, so they aren't lost. */
export function unplacedFieldErrors(fields: Readonly<Record<string, string>>, shown: ReadonlySet<string>): string[] {
  return Object.entries(fields).filter(([key]) => !shown.has(key)).map(([, reason]) => reason);
}

// MARK: Refresh and pending changes

/** What the main window's tab-list poll says about the Mac's settings. */
export interface SettingsRevisionInfo {
  supportsSettings: boolean;
  settingsRevision: string;
}

/** Reload when the polled revision moved past the one shown. */
export function needsReload(shown: string | null | undefined, polled: SettingsRevisionInfo | null): boolean {
  return Boolean(polled?.supportsSettings && polled.settingsRevision && shown && polled.settingsRevision !== shown);
}

/** Seconds until the Mac undoes `pending`, counting down from when it arrived. */
export function pendingSecondsLeft(pending: Pick<SettingsPending, "secondsLeft">, receivedAt: number, now: number): number {
  return Math.max(0, Math.ceil(pending.secondsLeft - Math.max(0, now - receivedAt) / 1000));
}

export function pendingText(pending: Pick<SettingsPending, "summary">, seconds: number): string {
  return `Keep ${pending.summary}? Undoes in ${seconds} s`;
}

// MARK: Display

/** A slider's value: "85%" for `percent`, else the number and its unit. */
export function numberText(field: SettingsField, value: number | undefined): string {
  if (value === undefined || !Number.isFinite(value)) return "";
  if (field.format === "percent") return `${Math.round(value * 100)}%`;
  const text = String(Math.round(value * 100) / 100);
  return field.unit ? `${text} ${field.unit}` : text;
}

/** A port box's text: empty for 0 when 0 has a name (the name is the placeholder). */
export function portText(field: SettingsField, value: SettingsValue | undefined): string {
  if (typeof value !== "number") return "";
  return value === 0 && field.zeroLabel !== undefined ? "" : String(value);
}

export function secretStatus(field: Pick<SettingsField, "isSet">): string {
  return field.isSet ? "Set" : "Not set";
}

/** A value with no control of its own (info lines). */
export function valueText(value: SettingsValue | undefined): string {
  if (value === undefined) return "";
  if (typeof value === "boolean") return value ? "On" : "Off";
  return String(value);
}

/** An info line's colour class for its `tone`. */
export function toneClass(tone: string | undefined): string {
  return tone === "error" ? "red" : tone === "warning" ? "orange" : "muted";
}

/** A DOM id for a field's control (its label and help point at it). */
export function fieldDOMID(key: string, suffix = ""): string {
  return `mac-setting-${key.replace(/[^A-Za-z0-9_-]/g, "-")}${suffix ? `-${suffix}` : ""}`;
}

// MARK: Nested pages

/** The parts of a keydown that decide whether it goes back from a section opened as its own page. */
export interface BackKey {
  key: string;
  altKey: boolean;
  ctrlKey: boolean;
  metaKey: boolean;
  shiftKey: boolean;
  /** A control already used it (a box's Escape puts back its saved value). */
  defaultPrevented: boolean;
  /** Focus is in a box you type in. */
  editable: boolean;
}

/**
 * On a section opened as its own page: Alt+Left goes back; Escape goes back, or first ends the
 * edit in a box (as clicking away does); Backspace goes back outside boxes. Windows has no swipe.
 */
export function settingsBackKey(event: BackKey): "back" | "endEdit" | null {
  if (event.defaultPrevented || event.metaKey) return null;
  if (event.key === "ArrowLeft") return event.altKey && !event.ctrlKey && !event.shiftKey ? "back" : null;
  if (event.altKey || event.ctrlKey) return null;
  if (event.key === "Escape") return event.editable ? "endEdit" : "back";
  if (event.key === "Backspace" && !event.shiftKey) return event.editable ? null : "back";
  return null;
}

const TYPED_INPUTS = new Set(["", "text", "search", "url", "email", "password", "number", "tel"]);

/** Whether an element takes typing (so Backspace and Escape belong to it). */
export function isEditableTarget(target: { tagName?: string; type?: string; isContentEditable?: boolean; readOnly?: boolean } | null): boolean {
  if (!target) return false;
  if (target.isContentEditable) return true;
  const tag = target.tagName?.toUpperCase();
  if (tag === "TEXTAREA") return !target.readOnly;
  if (tag === "INPUT") return TYPED_INPUTS.has((target.type ?? "").toLowerCase()) && !target.readOnly;
  return false;
}
