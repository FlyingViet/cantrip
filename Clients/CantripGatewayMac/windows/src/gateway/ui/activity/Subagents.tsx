// Subagent monitor (CantripSubagentMonitor.swift): cards for a reply's subagents, live ones pinned above
// the composer, and a tab's "N background tasks" button.
import "./activity.css";
import type { JSX } from "preact";
import { useState } from "preact/hooks";
import type { RemoteReasoningStep, RemoteSubagent } from "../../api/types";
import { now } from "../../state/clock";
import * as remote from "../../state/remote";
import { Icon, StatusIcon } from "../icons";
import { confirmDialog, Spinner } from "../kit";
import { inline } from "../transcript/Markdown";
import {
  activeBackground, backgroundTaskAccessibilityLabel, backgroundTaskIcon, backgroundTaskSummary, backgroundTaskTitle,
  canStopSubagent, isLive, QUEUED_HINT, recentStepsTitle, stackLayout, stepLabel, subagentAccessibilityLabel,
  subagentCurrentWork, subagentDisplayName, subagentMetaLine, subagentState, subagentStatusText, subagentSummaryLine, trimmed,
} from "./activityLogic";
import { FilledGlyph } from "./glyphs";

function SubagentStatusIcon(props: { agent: RemoteSubagent }): JSX.Element {
  switch (subagentState(props.agent)) {
    case "queued": return <Icon name="clock" size={16} class="muted" />;
    case "running":
    case "working": return <Spinner size="small" />;
    case "idle": return <FilledGlyph kind="pause" tint="blue" />;
    case "completed": return <StatusIcon kind="succeeded" />;
    case "failed": return <Icon name="exclamationmark.triangle" size={16} class="orange" />;
    case "cancelled": return <FilledGlyph kind="xmark" tint="gray" />;
  }
}

function StepStateIcon(props: { state: string }): JSX.Element {
  switch (props.state) {
    case "succeeded": return <StatusIcon kind="succeeded" size={14} />;
    case "failed": return <StatusIcon kind="failed" size={14} />;
    case "cancelled": return <FilledGlyph kind="xmark" tint="gray" size={14} />;
    default: return <Spinner size="small" />;
  }
}

export function SubagentErrorRow(props: { message: string }): JSX.Element {
  return (
    <div class="act-error-row" role="alert">
      <Icon name="exclamationmark.triangle" size={14} class="red" />
      <span class="selectable">{props.message}</span>
    </div>
  );
}

function Badge(props: { text: string }): JSX.Element {
  return <span class="act-badge">{props.text}</span>;
}

// MARK: Reasoning steps (CantripReasoningStepList)

function ReasoningStepRow(props: { step: RemoteReasoningStep; number: number; isCurrent: boolean }): JSX.Element {
  const { step, number, isCurrent } = props;
  const [expanded, setExpanded] = useState(false);
  const title = step.title || `Step ${number}`;
  const hasDetails = trimmed(step.text) !== "";
  const label = [`Step ${number}`, title, ...(isCurrent ? ["in progress"] : [])].join(", ");
  const body = (
    <>
      <span class={`act-step-number${isCurrent ? " current" : ""}`} aria-hidden="true">{number}</span>
      <span class="act-step-title" aria-hidden="true">{inline(title, null, `r${number}`)}</span>
      {hasDetails ? <Icon name={expanded ? "chevron.down" : "chevron.right"} size={12} class="act-chevron" /> : null}
    </>
  );
  return (
    <div class="act-step">
      {hasDetails ? (
        <button type="button" class="act-step-row" aria-expanded={expanded ? "true" : "false"} aria-label={label}
          title={expanded ? "Hides this step's details" : "Shows this step's details"} onClick={() => setExpanded(!expanded)}>
          {body}
        </button>
      ) : <div class="act-step-row" role="group" aria-label={label}>{body}</div>}
      {expanded && hasDetails ? <div class="act-step-text selectable">{inline(step.text, null, `rt${number}`)}</div> : null}
    </div>
  );
}

function ReasoningStepList(props: { steps: RemoteReasoningStep[]; streaming: boolean }): JSX.Element {
  // Rows keep their identity by step number as older subagent steps scroll out.
  const numbered = props.steps.map((step, index) => ({ step, number: step.number ?? index + 1 }));
  const last = numbered[numbered.length - 1]?.number;
  return (
    <div class="act-steps" role="list" aria-label={`Reasoning, ${stepLabel(numbered.length)}`}>
      {numbered.map((item) => (
        <div role="listitem" key={item.number}>
          <ReasoningStepRow step={item.step} number={item.number} isCurrent={props.streaming && item.number === last} />
        </div>
      ))}
    </div>
  );
}

// MARK: Card

/** One subagent: status, name, badges, what it's doing now, elapsed time and tokens, and Stop. */
export function SubagentCard(props: { sessionID: string | null | undefined; subagent: RemoteSubagent }): JSX.Element {
  const { subagent: agent, sessionID } = props;
  const [expanded, setExpanded] = useState(false);
  const [stopping, setStopping] = useState(false);
  const [stopError, setStopError] = useState<string | null>(null);
  // Live cards tick every second; finished ones keep their final time.
  const seconds = (isLive(agent) ? now.value : Date.now()) / 1000;
  const name = subagentDisplayName(agent);
  const type = trimmed(agent.agentType);
  const summary = subagentSummaryLine(agent);
  const current = subagentCurrentWork(agent);
  const state = subagentState(agent);
  const error = trimmed(agent.error);
  const latest = trimmed(agent.latestMessage);
  const reasoning = agent.reasoning ?? [];
  const steps = agent.recentSteps ?? [];

  const stop = async () => {
    const confirmed = await confirmDialog({
      title: "Stop this subagent?", message: "Cantrip will stop this subagent if it is still running.",
      confirm: `Stop ${name}`, destructive: true,
    });
    if (!confirmed || stopping || !sessionID) return;
    setStopping(true);
    setStopError(null);
    try {
      const result = await remote.cancelSubagent(sessionID, agent.agentID);
      if (result?.cancelled === false) setStopError("It had already finished.");
    } catch (failure) {
      setStopError((failure as Error).message || "Could not stop this subagent.");
    } finally {
      setStopping(false);
    }
  };

  return (
    <section class={`act-subagent${isLive(agent) ? " live" : ""}`} data-agent-id={agent.agentID}>
      <div class="act-subagent-top">
        <button type="button" class="act-subagent-head" aria-expanded={expanded ? "true" : "false"}
          aria-label={subagentAccessibilityLabel(agent, seconds)}
          title={expanded ? "Collapse subagent details" : "Expand subagent details"} onClick={() => setExpanded(!expanded)}>
          <span class="act-subagent-icon"><SubagentStatusIcon agent={agent} /></span>
          <span class="act-subagent-titles">
            <span class="act-subagent-status">
              <span>{subagentStatusText(agent)}</span>
              {type ? <Badge text={type} /> : null}
              {agent.background ? <Badge text="Background" /> : null}
            </span>
            <span class="act-subagent-name">{name}</span>
          </span>
          <Icon name={expanded ? "chevron.down" : "chevron.right"} size={12} class="act-chevron" />
        </button>
        {canStopSubagent(agent, sessionID) ? (
          <button type="button" class="btn small destructive act-stop" disabled={stopping} aria-label={`Stop ${name}`}
            title="Stop only this subagent. The reply keeps going." onClick={() => void stop()}>
            {stopping ? "Stopping..." : "Stop"}
          </button>
        ) : null}
      </div>
      {summary ? <p class="act-line muted selectable">{summary}</p> : null}
      {state === "queued" ? <p class="act-line muted">{QUEUED_HINT}</p> : null}
      {current ? <p class="act-line selectable">Now: {current}</p> : null}
      <p class="act-line muted act-meta">{subagentMetaLine(agent, seconds)}</p>
      {state === "failed" && error ? <SubagentErrorRow message={error} /> : null}
      {stopError ? <SubagentErrorRow message={stopError} /> : null}
      {expanded ? (
        <div class="act-subagent-details">
          {reasoning.length ? <ReasoningStepList steps={reasoning} streaming={state === "running"} /> : null}
          {latest ? (
            <div class="act-latest">
              <div class="act-line act-strong">Latest</div>
              <p class="act-line muted selectable">{latest}</p>
            </div>
          ) : null}
          {steps.length ? (
            <div class="act-recent">
              <div class="act-line act-strong">{recentStepsTitle(agent)}</div>
              <ul class="act-recent-list">
                {steps.map((step, index) => (
                  <li key={`${index}:${step.title}:${step.toolName}`} class="act-recent-step">
                    <span class="act-recent-icon"><StepStateIcon state={step.state} /></span>
                    <span class="grow selectable">{step.title || step.toolName}</span>
                    {step.toolName && step.title ? <span class="act-recent-tool">{step.toolName}</span> : null}
                  </li>
                ))}
              </ul>
            </div>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}

// MARK: Stacks

function FinishedGroup(props: { sessionID: string | null | undefined; subagents: RemoteSubagent[] }): JSX.Element {
  const [expanded, setExpanded] = useState(false);
  return (
    <div class="act-finished">
      <button type="button" class="act-finished-head" aria-expanded={expanded ? "true" : "false"} onClick={() => setExpanded(!expanded)}>
        <Icon name="checkmark.circle" size={14} />
        <span class="grow">{props.subagents.length} finished</span>
        <Icon name={expanded ? "chevron.down" : "chevron.right"} size={12} class="act-chevron" />
      </button>
      {expanded ? (
        <div class="act-stack act-finished-body">
          {props.subagents.map((agent) => <SubagentCard key={agent.id} sessionID={props.sessionID} subagent={agent} />)}
        </div>
      ) : null}
    </div>
  );
}

/** Subagent cards inside a reply (and the Background lists). More than three fold the finished ones. */
export function SubagentStack(props: { sessionID: string; subagents: RemoteSubagent[] }): JSX.Element | null {
  if (!props.subagents.length) return null;
  const { primary, finished } = stackLayout(props.subagents);
  return (
    <div class="act-stack">
      {primary.map((agent) => <SubagentCard key={agent.id} sessionID={props.sessionID} subagent={agent} />)}
      {finished.length ? <FinishedGroup sessionID={props.sessionID} subagents={finished} /> : null}
    </div>
  );
}

/** Running foreground subagents stay pinned above the composer so a growing reply can't scroll them away. */
export function PinnedSubagents(props: { sessionID: string; subagents: RemoteSubagent[]; maxHeight: number }): JSX.Element | null {
  if (!props.subagents.length) return null;
  return (
    <section class="act-pinned" aria-label="Running subagents" data-id="chat.pinnedSubagents">
      <div class="act-pinned-scroll" style={{ maxHeight: `${Math.max(0, props.maxHeight)}px` }}>
        <div class="act-stack">
          {props.subagents.map((agent) => <SubagentCard key={agent.id} sessionID={props.sessionID} subagent={agent} />)}
        </div>
      </div>
    </section>
  );
}

/** "2 background tasks · Build watcher · Running · 3m 05s" above a tab's composer. */
export function BackgroundTaskButton(props: { subagents: RemoteSubagent[]; onOpen: () => void }): JSX.Element | null {
  const active = activeBackground(props.subagents);
  if (!active.length) return null;
  const seconds = now.value / 1000;
  const icon = backgroundTaskIcon(active);
  return (
    <button type="button" class="act-task-button" onClick={props.onOpen} aria-label={backgroundTaskAccessibilityLabel(active, seconds)}
      title="Show this tab's background tasks" data-id="chat.backgroundTasks">
      <span class="act-task-icon">
        {icon === "spinner" ? <Spinner size="small" /> : icon === "clock" ? <Icon name="clock" size={16} class="muted" /> : <FilledGlyph kind="pause" tint="blue" />}
      </span>
      <span class="act-task-text">
        <span class="act-task-title">{backgroundTaskTitle(active.length)}</span>
        <span class="act-task-summary truncate">{backgroundTaskSummary(active, seconds)}</span>
      </span>
      <Icon name="chevron.right" size={12} class="act-chevron" />
    </button>
  );
}
