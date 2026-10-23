// Edit Task (CantripHomeTaskEditView) and the record editor (CantripHomeTaskRecordEditor) sheets.
import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { HomeTask, HomeTaskField, HomeTaskRecord } from "../../api/types";
import { appleDate } from "../../state/format";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { FormRow, FormSection, Sheet } from "../kit";
import {
  canSaveRecord, capitalized, formatDayTime, fromLocalInput, initialRecordValues, isScheduled, toLocalInput,
} from "./homeLogic";
import { homeDataError, mutationError, saveRecord, updateTask } from "./homeState";
import { ErrorLine, RunSummary } from "./parts";

export function TaskEditSheet(props: { task: HomeTask; onClose: () => void }): JSX.Element {
  const task = remote.homeTasks.value?.tasks.find((item) => item.id === props.task.id) ?? props.task;
  const [title, setTitle] = useState(props.task.title);
  const [prompt, setPrompt] = useState(props.task.prompt);
  const [saving, setSaving] = useState(false);
  const run = task.runs[0];
  const earlier = task.runs.slice(1, 5);
  const workspace = task.workspace;
  const canSave = !saving && title.trim() !== "" && prompt.trim() !== "";
  const chat = (prefill: string) => {
    props.onClose();
    nav.openChat(prefill);
  };
  const save = async () => {
    if (!canSave) return;
    setSaving(true);
    const saved = await updateTask(task, { title, prompt });
    setSaving(false);
    if (saved) props.onClose();
  };
  return (
    <Sheet title="Edit Task" onClose={props.onClose} width={560} fit locked={saving}
      footer={<>
        <button type="button" class="btn" onClick={props.onClose} disabled={saving}>Cancel</button>
        <button type="button" class="btn primary" disabled={!canSave} onClick={() => void save()}>{saving ? "Saving…" : "Save"}</button>
      </>}>
      <form onSubmit={(event) => { event.preventDefault(); void save(); }}>
        <ErrorLine text={mutationError.value} class="hm-sheet-error" />
        <FormSection header="Task">
          <FormRow label={<label for="hm-task-title">Title</label>}>
            <input id="hm-task-title" class="text-field hm-field" value={title} data-autofocus
              onInput={(event) => setTitle(event.currentTarget.value)} />
          </FormRow>
          <FormRow stack label={<label for="hm-task-prompt">Instructions</label>}>
            <textarea id="hm-task-prompt" class="text-field hm-textarea" rows={7} value={prompt}
              onInput={(event) => setPrompt(event.currentTarget.value)}
              onKeyDown={(event) => { if (event.key === "Enter" && (event.ctrlKey || event.metaKey)) { event.preventDefault(); void save(); } }} />
          </FormRow>
        </FormSection>
        {isScheduled(task) ? (
          <FormSection header="Schedule" footer="To change the schedule, ask Cantrip Home in Chat.">
            <FormRow label="Runs"><span class="form-value selectable">{task.schedule.summary}</span></FormRow>
            <FormRow label="Time zone"><span class="form-value selectable">{task.schedule.timeZone}</span></FormRow>
            <FormRow>
              <button type="button" class="btn link" onClick={() => chat(`Change the schedule for ${task.title} to `)}>Change schedule in Chat</button>
            </FormRow>
          </FormSection>
        ) : null}
        {workspace ? (
          <FormSection header="Workspace">
            <FormRow label={workspace.recordLabel}><span class="form-value">{workspace.records.length}</span></FormRow>
            <FormRow label="Fields"><span class="form-value">{workspace.fields.length}</span></FormRow>
            <FormRow>
              <button type="button" class="btn link" onClick={() => chat(`Change the workspace for ${task.title} to `)}>Change workspace in Chat</button>
            </FormRow>
          </FormSection>
        ) : null}
        {run ? (
          <FormSection header="Latest run">
            <FormRow label="Status"><span class="form-value">{capitalized(run.status)}</span></FormRow>
            {run.summary ? <FormRow><RunSummary summary={run.summary} class="selectable hm-sheet-summary" /></FormRow> : null}
          </FormSection>
        ) : null}
        {earlier.length ? (
          <FormSection header="Earlier runs">
            {earlier.map((item) => (
              <FormRow key={item.id} stack>
                <span class="hm-run-meta">{formatDayTime(appleDate(item.finishedAt))} · {capitalized(item.status)}</span>
                {item.summary ? <RunSummary summary={item.summary} lineLimit={3} class="selectable hm-sheet-summary" /> : null}
              </FormRow>
            ))}
          </FormSection>
        ) : null}
      </form>
    </Sheet>
  );
}

export function RecordEditorSheet(props: { taskID: string; record: HomeTaskRecord | null; onClose: () => void }): JSX.Element | null {
  const task = remote.homeTasks.value?.tasks.find((item) => item.id === props.taskID);
  const [workspace] = useState(() => task?.workspace ?? null);
  const [values, setValues] = useState<Record<string, string>>(() => (workspace ? initialRecordValues(workspace, props.record) : {}));
  const [saving, setSaving] = useState(false);
  useEffect(() => { if (!workspace) props.onClose(); }, []);
  if (!workspace) return null;
  const label = workspace.recordLabel;
  const canSave = !saving && canSaveRecord(workspace, values);
  const set = (key: string, value: string | null) => setValues((current) => {
    const next = { ...current };
    if (value === null) delete next[key];
    else next[key] = value;
    return next;
  });
  const save = async () => {
    if (!canSave) return;
    setSaving(true);
    const saved = await saveRecord(props.taskID, props.record?.id ?? null, values);
    setSaving(false);
    if (saved) props.onClose();
  };
  return (
    <Sheet title={props.record ? `Edit ${label}` : `Add ${label}`} onClose={props.onClose} width={560} fit locked={saving}
      footer={<>
        <button type="button" class="btn" onClick={props.onClose} disabled={saving}>Cancel</button>
        <button type="button" class="btn primary" disabled={!canSave} onClick={() => void save()}>{saving ? "Saving…" : "Save"}</button>
      </>}>
      <form onSubmit={(event) => { event.preventDefault(); void save(); }}>
        {homeDataError.value ? <FormSection><FormRow><ErrorLine text={homeDataError.value} /></FormRow></FormSection> : null}
        <FormSection header={label}>
          {workspace.fields.map((field, index) => (
            <FieldEditor key={field.key} field={field} id={`hm-field-${index}`} value={values[field.key]} first={index === 0}
              onChange={(value) => set(field.key, value)} />
          ))}
        </FormSection>
        <button type="submit" hidden />
      </form>
    </Sheet>
  );
}

function FieldEditor(props: { field: HomeTaskField; id: string; value: string | undefined; first: boolean; onChange: (value: string | null) => void }): JSX.Element {
  const { field, id } = props;
  const value = props.value ?? "";
  const common = { id, "aria-required": field.required ? ("true" as const) : undefined, "data-autofocus": props.first ? "" : undefined };
  const labelled = (control: JSX.Element, stack = false) => (
    <FormRow stack={stack} label={<label for={id}>{field.label}</label>}>{control}</FormRow>
  );
  switch (field.kind) {
    case "longText":
      return labelled(
        <textarea {...common} class="text-field hm-textarea" rows={4} value={value} placeholder={field.label}
          onInput={(event) => props.onChange(event.currentTarget.value)} />, true);
    case "number":
      return labelled(
        <input {...common} class="text-field hm-field" inputMode="decimal" value={value} placeholder={field.label}
          onInput={(event) => props.onChange(event.currentTarget.value)} />);
    case "boolean":
      return labelled(
        <input {...common} type="checkbox" role="switch" class="switch" checked={value === "true"}
          onChange={(event) => props.onChange(event.currentTarget.checked ? "true" : "false")} />);
    case "date":
      return labelled(
        <input {...common} type="date" class="text-field hm-field-date" value={value}
          onInput={(event) => {
            const next = event.currentTarget.value;
            props.onChange(next || (field.required ? "" : null));
          }} />);
    case "dateTime":
      return labelled(
        <input {...common} type="datetime-local" class="text-field hm-field-date" value={toLocalInput(props.value)}
          onInput={(event) => {
            const next = fromLocalInput(event.currentTarget.value);
            props.onChange(next ?? (field.required ? "" : null));
          }} />);
    case "choice": {
      const options = field.options ?? [];
      return labelled(
        <select {...common} class="select hm-field" value={value} onChange={(event) => props.onChange(event.currentTarget.value)}>
          <option value="">Select</option>
          {value && !options.includes(value) ? <option value={value}>{value}</option> : null}
          {options.map((option) => <option key={option} value={option}>{option}</option>)}
        </select>);
    }
    case "url":
      return labelled(
        <input {...common} type="url" class="text-field hm-field" value={value} placeholder={field.label} spellcheck={false}
          autocapitalize="off" autocomplete="off" onInput={(event) => props.onChange(event.currentTarget.value)} />);
    default:
      return labelled(
        <input {...common} class="text-field hm-field" value={value} placeholder={field.label}
          onInput={(event) => props.onChange(event.currentTarget.value)} />);
  }
}
