// Each tab lists the background agents the Mac still runs in `backgroundTaskIDs` (each a reply's `subagents[].id`).
// Older replies paged in earlier stay cached without being fetched again, so a watcher that finished after its reply
// left the recent window would stay "running" here, with a Stop the Mac answers "already finished". Any background
// agent missing from the list shows as finished (CantripRemoteSession.settleBackgroundAgents in CantripRemote.swift).
import type { RemoteMessage, RemoteSubagent } from "../api/types";
import { isLive } from "../ui/activity/activityLogic";

function isStale(agent: RemoteSubagent, running: ReadonlySet<string>): boolean {
  return agent.background && isLive(agent) && !running.has(agent.id);
}

/** The same array when nothing changes, or when the Mac sent no list (older Macs). */
export function settleBackgroundAgents(messages: RemoteMessage[], ids: readonly string[] | null | undefined): RemoteMessage[] {
  if (!Array.isArray(ids)) return messages;
  const running: ReadonlySet<string> = new Set(ids);
  let changed = false;
  const settled = messages.map((message) => {
    if (!message.subagents?.some((agent) => isStale(agent, running))) return message;
    changed = true;
    return {
      ...message,
      subagents: message.subagents.map((agent): RemoteSubagent => (isStale(agent, running) ? { ...agent, status: "completed", canCancel: false } : agent)),
    };
  });
  return changed ? settled : messages;
}
