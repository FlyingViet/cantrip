// A workspace task's records (CantripHomeTaskWorkspaceView), grouped into collapsible sections when its list
// declares a group field, and one record's details (CantripHomeTaskRecordDetailView).
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import type { HomeTask, HomeTaskField, HomeTaskRecord, HomeTaskWorkspace } from "../../api/types";
import { bridge } from "../../bridge";
import { appleDate } from "../../state/format";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { confirmDialog, FormRow, FormSection, MenuButton, type MenuEntry } from "../kit";
import {
  badgeTone, detailSections, displayValue, fieldFor, filterRecords, formatDayTime, isSectionCollapsed, loadGroupState,
  pluralLabel, recordBadge, recordDate, recordNoun, recordSubtitle, recordTitle, saveGroupState, workspaceSections,
  type WorkspaceSection,
} from "./homeLogic";
import { deleteRecord, homeDataError } from "./homeState";
import { contextMenuAt, ErrorLine, PaneBar, ScrollArea, Unavailable } from "./parts";
import { SymbolIcon } from "./symbols";
import * as tasksNav from "./tasksNav";

function findTask(taskID: string): HomeTask | undefined {
  return remote.homeTasks.value?.tasks.find((task) => task.id === taskID);
}

function confirmDeleteRecord(taskID: string, workspace: HomeTaskWorkspace | undefined, recordID: string, then?: () => void): void {
  void confirmDialog({ title: `Delete ${workspace?.recordLabel.toLowerCase() ?? "record"}?`, confirm: "Delete", destructive: true })
    .then(async (confirmed) => {
      if (confirmed && (await deleteRecord(taskID, recordID))) then?.();
    });
}

export function WorkspaceView(props: { taskID: string }): JSX.Element {
  const task = findTask(props.taskID);
  const workspace = task?.workspace;
  const query = tasksNav.search.value;
  const searching = query.trim() !== "";
  const [collapsed, setCollapsed] = useState(() => loadGroupState(props.taskID, localStorage));

  const bar = (
    <PaneBar backLabel="Tasks" onBack={tasksNav.back} title={task?.title ?? "Task"}>
      {workspace && workspace.records.length ? (
        <label class="hm-search">
          <Icon name="magnifyingglass" size={14} />
          <input type="search" class="hm-search-input" placeholder={`Search ${pluralLabel(workspace)}`}
            aria-label={`Search ${pluralLabel(workspace)}`} value={query}
            onInput={(event) => { tasksNav.search.value = event.currentTarget.value; }}
            onKeyDown={(event) => { if (event.key === "Escape" && query) { event.stopPropagation(); tasksNav.search.value = ""; } }} />
        </label>
      ) : null}
      <div class="glass-group">
        <button type="button" class="glass-btn" aria-label="Task settings" title="Task settings" disabled={!task}
          aria-haspopup="dialog" onClick={() => { if (task) tasksNav.editingTask.value = task; }}>
          <Icon name="gearshape" size={18} />
        </button>
        <button type="button" class="glass-btn" aria-label={`Add ${workspace?.recordLabel ?? "record"}`}
          title={`Add ${workspace?.recordLabel ?? "record"}`} disabled={!workspace} aria-haspopup="dialog"
          onClick={() => { tasksNav.recordEditor.value = { taskID: props.taskID, record: null }; }}>
          <Icon name="plus" size={18} />
        </button>
      </div>
    </PaneBar>
  );

  if (!task || !workspace) {
    return <>{bar}<Unavailable icon={<Icon name="rectangle.stack" size={56} />} title="Task unavailable" description="Refresh Tasks and try again." /></>;
  }
  if (!workspace.records.length) {
    return (
      <>
        {bar}
        <Unavailable icon={<SymbolIcon name={workspace.icon} size={56} />} title={`No ${pluralLabel(workspace)} yet`}
          description="Add one here or tell Cantrip Home about it in Chat." error={homeDataError.value}
          action={<button type="button" class="btn primary large" aria-haspopup="dialog"
            onClick={() => { tasksNav.recordEditor.value = { taskID: task.id, record: null }; }}>Add {workspace.recordLabel}</button>} />
      </>
    );
  }

  const records = filterRecords(workspace.records, query);
  const sections = workspaceSections(workspace, records, searching);
  const toggle = (section: WorkspaceSection) => {
    const next = { ...collapsed, [section.id]: !isSectionCollapsed(section, collapsed) };
    setCollapsed(next);
    saveGroupState(task.id, next, localStorage);
  };
  const list = (items: HomeTaskRecord[]) => (
    <ul class="hm-record-list">
      {items.map((record) => <RecordRow key={record.id} task={task} workspace={workspace} record={record} />)}
    </ul>
  );

  return (
    <>
      {bar}
      <ScrollArea scrollKey={`workspace:${task.id}`} saved={tasksNav.savedScroll} onSave={tasksNav.saveScroll} onRendered={tasksNav.restoreFocus}>
        <ErrorLine text={homeDataError.value} class="hm-error-banner" />
        <div class="sr-only" role="status" aria-live="polite">
          {searching ? `${records.length} ${recordNoun(workspace, records.length)} found` : ""}
        </div>
        {searching && !records.length ? <p class="hm-no-matches">No {pluralLabel(workspace)} match.</p> : null}
        {sections ? sections.map((section) => {
          const expanded = searching || !isSectionCollapsed(section, collapsed);
          const noun = recordNoun(workspace, section.records.length);
          return (
            <section key={section.id} class="hm-group">
              <h3 class="hm-group-heading">
                <button type="button" class="hm-group-header" aria-expanded={searching ? undefined : expanded}
                  aria-disabled={searching ? "true" : undefined} aria-label={`${section.title}, ${section.records.length} ${noun}`}
                  title={searching ? undefined : expanded ? "Collapses this section." : "Expands this section."}
                  data-focus-key={`group:${section.id}`} data-id={`workspace.section.${section.title}`}
                  onClick={() => { if (!searching) toggle(section); }}>
                  <span class="hm-group-title">{section.title}</span>
                  <span class="hm-group-count">{section.records.length}</span>
                  <span class="grow" />
                  {!searching ? <Icon name="chevron.right" size={14} class={`hm-chevron${expanded ? " open" : ""}`} /> : null}
                </button>
              </h3>
              {expanded ? list(section.records) : null}
            </section>
          );
        }) : list(records)}
      </ScrollArea>
    </>
  );
}

function RecordRow(props: { task: HomeTask; workspace: HomeTaskWorkspace; record: HomeTaskRecord }): JSX.Element {
  const { task, workspace, record } = props;
  const title = recordTitle(workspace, record);
  const badge = recordBadge(workspace, record);
  const subtitle = recordSubtitle(workspace, record);
  const date = recordDate(workspace, record);
  const entries = (): MenuEntry[] => [
    { label: "Open", icon: "arrow.up.forward.square", onSelect: () => tasksNav.openRecord(task.id, record.id) },
    { label: "Edit…", icon: "pencil", onSelect: () => { tasksNav.recordEditor.value = { taskID: task.id, record }; } },
    { kind: "separator" },
    { label: "Delete", icon: "trash", destructive: true, disabled: remote.isMutating.value, onSelect: () => confirmDeleteRecord(task.id, workspace, record.id) },
  ];
  return (
    <li class="hm-record-item">
      <button type="button" class="hm-record" data-focus-key={`record:${record.id}`}
        aria-label={[title, badge, subtitle, date].filter(Boolean).join(", ")}
        onClick={() => tasksNav.openRecord(task.id, record.id)}
        onContextMenu={(event) => contextMenuAt(event, entries(), `${title} actions`)}>
        <span class="hm-record-icon accent"><SymbolIcon name={workspace.icon} size={20} /></span>
        <span class="hm-record-body">
          <span class="hm-record-head">
            <span class="hm-record-title">{title}</span>
            <span class="grow" />
            {badge ? <span class={`hm-badge tone-${badgeTone(badge)}`}>{badge}</span> : null}
          </span>
          {subtitle ? <span class="hm-record-subtitle hm-clamp" style={{ WebkitLineClamp: "2" }}>{subtitle}</span> : null}
          {date ? <span class="hm-record-date"><Icon name="calendar" size={12} />{date}</span> : null}
        </span>
      </button>
      <MenuButton class="icon-btn hm-hover-action hm-record-more" label={`Actions for ${title}`} entries={entries}>
        <Icon name="ellipsis" size={16} />
      </MenuButton>
    </li>
  );
}

export function RecordDetailView(props: { taskID: string; recordID: string }): JSX.Element {
  const task = findTask(props.taskID);
  const workspace = task?.workspace;
  const record = workspace?.records.find((item) => item.id === props.recordID);
  const title = workspace && record ? recordTitle(workspace, record) : "Record";
  const bar = (
    <PaneBar backLabel={task?.title ?? "Task"} onBack={tasksNav.back} title={title}>
      <button type="button" class="btn" disabled={!record} aria-haspopup="dialog"
        onClick={() => { if (record) tasksNav.recordEditor.value = { taskID: props.taskID, record }; }}>Edit</button>
      <button type="button" class="icon-btn hm-destructive" aria-label="Delete record" title="Delete record"
        disabled={!record || remote.isMutating.value}
        onClick={() => confirmDeleteRecord(props.taskID, workspace, props.recordID, () => {
          if (tasksNav.route.value.kind === "record") tasksNav.back();
        })}>
        <Icon name="trash" size={16} />
      </button>
    </PaneBar>
  );
  if (!workspace || !record) {
    return <>{bar}<Unavailable icon={<Icon name="questionmark.circle" size={56} />} title="Record unavailable" description="It may have been removed." /></>;
  }
  return (
    <>
      {bar}
      <ScrollArea scrollKey={`record:${props.taskID}:${props.recordID}`} saved={tasksNav.savedScroll} onSave={tasksNav.saveScroll} class="hm-detail">
        <ErrorLine text={homeDataError.value} class="hm-error-banner" />
        {detailSections(workspace).map((section, index) => (
          <FormSection key={`${section.title ?? ""}:${index}`} header={section.title || undefined}>
            {section.fields.map((key) => {
              const field = fieldFor(workspace, key);
              return field ? <RecordValue key={key} field={field} value={record.values[key]} /> : null;
            })}
          </FormSection>
        ))}
        <FormSection>
          <FormRow label="Updated"><span class="form-value selectable">{formatDayTime(appleDate(record.updatedAt))}</span></FormRow>
        </FormSection>
      </ScrollArea>
    </>
  );
}

function RecordValue(props: { field: HomeTaskField; value: string | undefined }): JSX.Element {
  const { field, value } = props;
  if (field.kind === "longText") {
    return (
      <FormRow stack>
        <span class="hm-field-label">{field.label}</span>
        <span class={`hm-long-value selectable${value === undefined ? " muted" : ""}`}>{value ?? "—"}</span>
      </FormRow>
    );
  }
  const link = field.kind === "url" && value && /^https?:\/\//i.test(value);
  return (
    <FormRow label={field.label}>
      {link ? (
        <a class="form-value hm-value-link selectable" href={value} onClick={(event) => { event.preventDefault(); bridge.openExternal(value!); }}>{value}</a>
      ) : (
        <span class={`form-value hm-value selectable${value === undefined ? " muted" : ""}`}>
          {value === undefined ? "—" : displayValue(value, field)}
        </span>
      )}
    </FormRow>
  );
}
