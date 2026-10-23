// Home's Tasks (CantripHomeTasksView): every task with its schedule, latest run and pause switch; a workspace
// task opens its records, any other task its Edit sheet. Drag, Alt+Up/Down or the row menu reorders.
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { HomeTask } from "../../api/types";
import { now } from "../../state/clock";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon, StatusIcon } from "../icons";
import { confirmDialog, MenuButton, Spinner, type MenuEntry } from "../kit";
import { isScheduled, taskStatusKind, taskSubtitle, taskTimeLine, waitingRuns } from "./homeLogic";
import { deleteTask, homeDataError, moveTask, moveTaskBy, pendingEnabled, updateTask } from "./homeState";
import { contextMenuAt, ErrorLine, HomeGate, RunSummary, ScrollArea, Unavailable } from "./parts";
import { NeedsInputGlyph, PausedGlyph, ScheduledGlyph, SymbolIcon, WarningGlyph } from "./symbols";
import { RecordEditorSheet, TaskEditSheet } from "./TaskSheets";
import { RecordDetailView, WorkspaceView } from "./TaskWorkspace";
import * as tasksNav from "./tasksNav";

export function TasksView(): JSX.Element {
  useEffect(() => {
    void remote.refreshHomeData();
    // Leaving Tasks dismisses its sheets, as the Mac's do when their view goes away.
    return () => {
      tasksNav.editingTask.value = null;
      tasksNav.recordEditor.value = null;
    };
  }, []);
  const editing = tasksNav.editingTask.value;
  const editor = tasksNav.recordEditor.value;
  return (
    <>
      <HomeGate>{() => <TasksRoute />}</HomeGate>
      {editing ? <TaskEditSheet task={editing} onClose={() => { tasksNav.editingTask.value = null; }} /> : null}
      {editor ? <RecordEditorSheet taskID={editor.taskID} record={editor.record} onClose={() => { tasksNav.recordEditor.value = null; }} /> : null}
    </>
  );
}

function TasksRoute(): JSX.Element {
  const current = tasksNav.route.value;
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.altKey && event.key === "ArrowLeft" && current.kind !== "list") {
      event.preventDefault();
      tasksNav.back();
    }
  };
  return (
    <div class="hm-root" onKeyDown={onKeyDown}>
      {current.kind === "list" ? <TaskList />
        : current.kind === "workspace" ? <WorkspaceView key={current.taskID} taskID={current.taskID} />
          : <RecordDetailView key={`${current.taskID}:${current.recordID}`} taskID={current.taskID} recordID={current.recordID} />}
    </div>
  );
}

function confirmDelete(task: HomeTask): void {
  void confirmDialog({ title: `Delete ${task.title || "task"}?`, confirm: "Delete task", destructive: true })
    .then((confirmed) => { if (confirmed) void deleteTask(task); });
}

function openTask(task: HomeTask): void {
  if (task.workspace) tasksNav.openWorkspace(task.id);
  else tasksNav.editingTask.value = task;
}

function focusTask(list: HTMLElement | null, id: string): void {
  list?.querySelector<HTMLElement>(`[data-focus-key="${CSS.escape(`task:${id}`)}"]`)?.focus();
}

function TaskList(): JSX.Element {
  const snapshot = remote.homeTasks.value;
  const tasks = snapshot?.tasks ?? [];
  const loading = snapshot === null && remote.homeTasksError.value === null;
  const error = homeDataError.value;
  const waiting = waitingRuns(remote.homeBackground.value);
  const canReorder = snapshot?.supportsReordering === true && !remote.isMutating.value && tasks.length > 1;
  const [drag, setDrag] = useState<{ id: string; over: string | null; after: boolean } | null>(null);
  const listRef = useRef<HTMLUListElement>(null);

  if (!tasks.length) {
    if (loading) return <div class="hm-unavailable" role="status"><Spinner size="large" label="Loading tasks" /></div>;
    return (
      <Unavailable icon={<Icon name="checklist" size={56} />} title="No tasks yet" error={error}
        description="Ask Cantrip Home to create a tracker or monitor something on a schedule."
        action={<button type="button" class="btn primary large" onClick={() => nav.openChat("Create a task for ")}>Create in Chat</button>} />
    );
  }

  const menu = (task: HomeTask): MenuEntry[] => {
    const index = tasks.findIndex((item) => item.id === task.id);
    const entries: MenuEntry[] = task.workspace
      ? [
        { label: "Open", icon: "arrow.up.forward.square", onSelect: () => tasksNav.openWorkspace(task.id) },
        { label: "Task Settings…", icon: "gearshape", onSelect: () => { tasksNav.editingTask.value = task; } },
      ]
      : [{ label: "Edit Task…", icon: "pencil", onSelect: () => { tasksNav.editingTask.value = task; } }];
    return [
      ...entries,
      { kind: "separator" },
      { label: "Move Up", icon: "arrow.up", shortcut: "Alt+↑", disabled: !canReorder || index <= 0, onSelect: () => void moveTaskBy(task.id, -1) },
      { label: "Move Down", icon: "arrow.down", shortcut: "Alt+↓", disabled: !canReorder || index >= tasks.length - 1, onSelect: () => void moveTaskBy(task.id, 1) },
      { kind: "separator" },
      { label: "Delete", icon: "trash", destructive: true, disabled: remote.isMutating.value, onSelect: () => confirmDelete(task) },
    ];
  };

  const onKeyDown = (event: KeyboardEvent) => {
    if (event.key !== "ArrowDown" && event.key !== "ArrowUp") return;
    const rows = Array.from(listRef.current?.querySelectorAll<HTMLElement>(".hm-task-main") ?? []);
    const index = rows.indexOf(document.activeElement as HTMLElement);
    if (index < 0) return;
    event.preventDefault();
    const offset = event.key === "ArrowUp" ? -1 : 1;
    if (event.altKey) {
      // Alt+Up/Down moves the focused task, like the Mac's Move up / Move down actions.
      const id = tasks[index]?.id;
      if (canReorder && id) void moveTaskBy(id, offset).then(() => focusTask(listRef.current, id));
      return;
    }
    rows[index + offset]?.focus();
  };

  return (
    <ScrollArea scrollKey="list" saved={tasksNav.savedScroll} onSave={tasksNav.saveScroll} onRendered={tasksNav.restoreFocus}>
      <ErrorLine text={error} class="hm-error-banner" />
      <ul ref={listRef} class="hm-task-list" aria-label="Tasks" onKeyDown={onKeyDown}>
        {tasks.map((task) => (
          <TaskRow key={task.id} task={task} waitingSession={waiting.get(task.id.toUpperCase())} draggable={canReorder}
            entries={() => menu(task)}
            dropClass={drag && drag.over === task.id && drag.id !== task.id ? (drag.after ? " drop-after" : " drop-before") : drag?.id === task.id ? " dragging" : ""}
            onDragStart={() => setDrag({ id: task.id, over: null, after: false })}
            onDragOver={(after) => setDrag((value) => (value ? { ...value, over: task.id, after } : value))}
            onDrop={() => {
              if (drag && drag.id !== task.id && canReorder) void moveTask(drag.id, task.id, drag.after);
              setDrag(null);
            }}
            onDragEnd={() => setDrag(null)} />
        ))}
      </ul>
    </ScrollArea>
  );
}

function TaskStatus(props: { task: HomeTask; waiting: boolean }): JSX.Element {
  const { task } = props;
  switch (taskStatusKind(task, props.waiting)) {
    case "needsInput": return <span title="Needs your input"><NeedsInputGlyph size={17} /></span>;
    case "running": return <span title="Running now"><Spinner size="small" /></span>;
    case "failed": return <span title="Failed"><WarningGlyph size={16} /></span>;
    case "succeeded": return <span title="Succeeded"><StatusIcon kind="succeeded" size={16} /></span>;
    case "paused": return <span title="Paused"><PausedGlyph size={16} /></span>;
    case "ready": return <span class="accent"><SymbolIcon name={task.workspace?.icon ?? "rectangle.stack.fill"} size={17} /></span>;
    default: return <span title="Scheduled"><ScheduledGlyph size={16} /></span>;
  }
}

const STATE_WORDS: Partial<Record<ReturnType<typeof taskStatusKind>, string>> = {
  needsInput: "Needs your input", running: "Running now", failed: "Failed", paused: "Paused",
};

function TaskRow(props: {
  task: HomeTask;
  waitingSession: string | undefined;
  draggable: boolean;
  entries: () => MenuEntry[];
  dropClass: string;
  onDragStart: () => void;
  onDragOver: (after: boolean) => void;
  onDrop: () => void;
  onDragEnd: () => void;
}): JSX.Element {
  const { task } = props;
  const line = taskTimeLine(task, now.value);
  const run = task.runs[0];
  const subtitle = taskSubtitle(task);
  const waiting = props.waitingSession !== undefined;
  const enabled = pendingEnabled.value.get(task.id) ?? task.enabled;
  const stateWord = STATE_WORDS[taskStatusKind(task, waiting)];
  const label = [...new Set([task.title, subtitle, stateWord, line.text, line.status].filter(Boolean))].join(", ");
  return (
    <li class={`hm-task${props.dropClass}`}
      onDragStart={(event) => {
        event.dataTransfer?.setData("text/plain", `cantrip-task:${task.id}`);
        if (event.dataTransfer) event.dataTransfer.effectAllowed = "move";
        props.onDragStart();
      }}
      onDragOver={(event) => {
        event.preventDefault();
        const box = (event.currentTarget as HTMLElement).getBoundingClientRect();
        props.onDragOver(event.clientY > box.top + box.height / 2);
      }}
      onDrop={(event) => { event.preventDefault(); props.onDrop(); }}
      onDragEnd={props.onDragEnd}>
      <button type="button" class="hm-task-main" data-focus-key={`task:${task.id}`} aria-label={label} draggable={props.draggable}
        aria-haspopup={task.workspace ? undefined : "dialog"} onClick={() => openTask(task)}
        onContextMenu={(event) => contextMenuAt(event, props.entries(), `${task.title} actions`)}>
        <span class="hm-task-head">
          <span class="hm-task-status"><TaskStatus task={task} waiting={waiting} /></span>
          <span class="hm-task-titles">
            <span class="hm-task-title">{task.title}</span>
            <span class="hm-task-subtitle">{subtitle}</span>
          </span>
        </span>
        <span class="hm-indent hm-task-prompt hm-clamp" style={{ WebkitLineClamp: "2" }}>{task.prompt}</span>
        <span class="hm-indent hm-task-meta">
          <Icon name={line.icon} size={12} />
          <span>{line.text}</span>
          {line.status ? <><span aria-hidden="true">·</span><span>{line.status}</span></> : null}
        </span>
        {run?.summary ? <RunSummary summary={run.summary} lineLimit={3} class="hm-indent hm-task-summary" /> : null}
      </button>
      <div class="hm-task-actions">
        <MenuButton class="icon-btn hm-hover-action" label={`Actions for ${task.title}`} entries={props.entries}>
          <Icon name="ellipsis" size={16} />
        </MenuButton>
        {isScheduled(task) ? (
          <input type="checkbox" class="checkbox hm-task-toggle" checked={enabled}
            disabled={remote.isMutating.value || task.state === "running"}
            aria-label={enabled ? `Pause ${task.title}` : `Resume ${task.title}`} title={enabled ? `Pause ${task.title}` : `Resume ${task.title}`}
            onChange={(event) => {
              const input = event.currentTarget;
              const next = input.checked;
              input.checked = enabled;
              void updateTask(task, { enabled: next });
            }} />
        ) : null}
      </div>
      {props.waitingSession !== undefined
        ? <NeedsInput title={task.title} onRespond={() => nav.showBackground(props.waitingSession)} />
        : null}
    </li>
  );
}

/** A task's live run waits on the user: say so and open its request in the Background list (CantripHomeRunNeedsInput). */
function NeedsInput(props: { title: string; onRespond: () => void }): JSX.Element {
  return (
    <div class="hm-indent hm-needs-input">
      <span class="hm-needs-label"><NeedsInputGlyph size={14} /> Needs your input</span>
      <span class="grow" />
      <button type="button" class="btn small hm-respond" aria-label={`Respond to ${props.title}`}
        title="Shows the run's request so you can answer it here" data-id="home.task.respond" onClick={props.onRespond}>
        Respond
      </button>
    </div>
  );
}
