// A tab's background tasks (CantripBackgroundTasksView): its build, upload and download watchers.
import "./activity.css";
import type { JSX } from "preact";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { Sheet } from "../kit";
import { backgroundSubagents, backgroundTasksStatusLine } from "./activityLogic";
import { SubagentStack } from "./Subagents";

export function DisconnectedNotice(props: { text: string }): JSX.Element | null {
  if (remote.isConnected.value) return null;
  return (
    <div class="act-disconnected" role="status">
      <Icon name="wifi.slash" size={14} />
      <span>{props.text}</span>
    </div>
  );
}

export function BackgroundTasksSheet(props: { sessionID: string; onClose: () => void }): JSX.Element {
  const detail = remote.details.value.get(props.sessionID);
  const tasks = backgroundSubagents(detail?.messages);
  return (
    <Sheet title="Background Tasks" onClose={props.onClose} width={620} height={560}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <DisconnectedNotice text="Disconnected. Showing the last known task status." />
      {tasks.length ? (
        <div class="act-content">
          <p class="act-line muted" role="status">{backgroundTasksStatusLine(tasks)}</p>
          <SubagentStack sessionID={props.sessionID} subagents={tasks} />
        </div>
      ) : (
        <div class="empty-state act-empty">
          <Icon name="clock" size={28} />
          <div class="title3">No background tasks</div>
          <p>Build, upload, download, and other background watchers appear here.</p>
        </div>
      )}
    </Sheet>
  );
}
