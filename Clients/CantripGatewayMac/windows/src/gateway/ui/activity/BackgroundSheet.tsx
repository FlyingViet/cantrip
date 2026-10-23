// Home's Background sheet (CantripHomeBackgroundView in CantripHomeBackground.swift): the chat's own
// background watchers plus scheduled-task and incident runs in the Mac's hidden sessions. Runs waiting on
// the user are answered here, in place, through each run's own session.
import "./activity.css";
import { computed } from "@preact/signals";
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import type { HomeBackgroundHandoff, HomeBackgroundQueuedRun, HomeBackgroundRun, InputDecision, InputRequest } from "../../api/types";
import { now } from "../../state/clock";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon, StatusIcon } from "../icons";
import { confirmDialog, Sheet, Spinner, toast } from "../kit";
import { inline } from "../transcript/Markdown";
import { InputCard } from "../transcript/Inputs";
import {
  answerResultText, backgroundPollDelay, backgroundSubagents, elapsedAccessibilityLabel, elapsedLabel, handoffIsActive,
  handoffNeedsAnswer, handoffStatusText, handoffSummary, handoffTabTitle, isLabelledSummary, needsInputRuns, otherRuns,
  queuedRunDetail, remainingInputs, runCanExpand, runDetail, runIcon, runIsRunning, runNeedsInput, runResult, runShowsResult,
  summaryLabel, summaryLines, trimmed,
} from "./activityLogic";
import { DisconnectedNotice } from "./BackgroundTasksSheet";
import { FilledGlyph, QuestionBubble } from "./glyphs";
import { SubagentStack } from "./Subagents";

/** Finished runs' "13 hours ago" refreshes every 30 s (TimelineView .periodic by 30 on the Mac). */
const halfMinute = computed(() => Math.floor(now.value / 30000) * 30000);

// MARK: Actions

/** Stops a running run or skips a waiting one (one request at a time, like the Mac). */
async function stopRun(id: string): Promise<void> {
  if (remote.homeBackground.peek()?.supportsStop !== true || remote.isMutating.peek()) return;
  try {
    await remote.mutate(() => remote.stopBackgroundRun(id));
    remote.homeBackgroundError.value = null;
  } catch (error) {
    remote.homeBackgroundError.value = (error as Error).message;
  }
}

// MARK: Pieces

function Section(props: { title: string; children: ComponentChildren }): JSX.Element {
  return (
    <section class="act-section" aria-label={props.title}>
      <h3 class="act-section-title">{props.title}</h3>
      {props.children}
    </section>
  );
}

function WarningRow(props: { text: string }): JSX.Element {
  return (
    <div class="act-warning-row" role="alert">
      <Icon name="exclamationmark.triangle" size={14} />
      <span class="selectable">{props.text}</span>
    </div>
  );
}

/** Stop for a running run, Skip for one still waiting; both confirm first. */
function StopButton(props: { title: "Stop" | "Skip"; label: string; action: () => Promise<void> }): JSX.Element {
  const [stopping, setStopping] = useState(false);
  const skip = props.title === "Skip";
  const click = async () => {
    const confirmed = await confirmDialog({
      title: skip ? "Skip this run?" : "Stop this background run?",
      message: skip ? "It won't run until its next scheduled time." : "Other background work keeps running.",
      confirm: `${props.title} ${props.label}`, destructive: true,
    });
    if (!confirmed) return;
    setStopping(true);
    try {
      await props.action();
    } finally {
      setStopping(false);
    }
  };
  return (
    <button type="button" class="btn small destructive act-run-stop" disabled={stopping} aria-label={`${props.title} ${props.label}`}
      onClick={() => void click()}>
      {stopping ? `${skip ? "Skipping" : "Stopping"}…` : props.title}
    </button>
  );
}

function HandoffIcon(props: { handoff: HomeBackgroundHandoff }): JSX.Element {
  if (handoffNeedsAnswer(props.handoff)) return <QuestionBubble size={16} />;
  switch (props.handoff.status) {
    case "queued": return <Icon name="clock" size={14} class="muted" />;
    case "running": return <Spinner size="small" />;
    case "completed": return <StatusIcon kind="succeeded" size={14} />;
    case "failed": return <Icon name="exclamationmark.triangle" size={14} class="orange" />;
    default: return <FilledGlyph kind="stop" tint="gray" size={14} />;
  }
}

/** A compact handoff card: status, tab, summary, elapsed time and Open tab (CantripHandoffCard). */
function HandoffCard(props: { handoff: HomeBackgroundHandoff }): JSX.Element {
  const { handoff } = props;
  const needs = handoffNeedsAnswer(handoff);
  const status = handoffStatusText(handoff);
  const tab = handoffTabTitle(handoff);
  const summary = handoffSummary(handoff);
  // Handoff dates are UnixSeconds (unlike the run's own).
  const seconds = (handoffIsActive(handoff) ? now.value : Date.now()) / 1000;
  const tabID = trimmed(handoff.tabID);
  return (
    <section class="act-handoff">
      <div class="act-handoff-head" role="group"
        aria-label={`${status}, ${tab}: ${summary}. ${elapsedAccessibilityLabel(handoff.startedAt, handoff.finishedAt, seconds)}`}>
        <span class="act-handoff-icon" aria-hidden="true"><HandoffIcon handoff={handoff} /></span>
        <div class="act-handoff-main" aria-hidden="true">
          <div class="act-handoff-status">
            <span class={needs ? "act-primary" : undefined}>{status}</span>
            <span class="act-tab-chip"><Icon name="rectangle.stack" size={12} /><span class="truncate">{tab}</span></span>
          </div>
          <div class="act-handoff-summary">{summary}</div>
        </div>
      </div>
      <div class="act-handoff-foot">
        <span class="act-line muted" aria-hidden="true">{elapsedLabel(handoff.startedAt, handoff.finishedAt, seconds)}</span>
        <span class="grow" />
        {tabID ? (
          <button type="button" class="btn plain small act-open-tab" aria-label={`Open ${tab} tab`}
            onClick={() => {
              if (!remote.sessions.value.some((item) => item.id === tabID)) { toast("That tab is no longer open."); return; }
              nav.openTab(tabID);
            }}>
            <Icon name="arrow.up.forward.square" size={14} />Open tab
          </button>
        ) : null}
      </div>
    </section>
  );
}

function QueuedRow(props: { item: HomeBackgroundQueuedRun; canSkip: boolean }): JSX.Element {
  const { item } = props;
  return (
    <div class="act-card" data-run-id={item.id}>
      <span class="act-card-icon"><Icon name="clock" size={16} class="muted" /></span>
      <div class="act-card-body">
        <div class="act-run-summary-block">
          <div class="act-run-label">{item.label}</div>
          <div class="act-run-detail">{queuedRunDetail(item)}</div>
        </div>
        {props.canSkip ? <div class="act-run-actions"><StopButton title="Skip" label={item.label} action={() => stopRun(item.id)} /></div> : null}
      </div>
    </div>
  );
}

function RunStatusIcon(props: { run: HomeBackgroundRun }): JSX.Element {
  switch (runIcon(props.run)) {
    case "needsInput": return <QuestionBubble size={18} label="Needs your input" />;
    case "tabQueued": return <Icon name="tray" size={16} class="muted" />;
    case "spinner": return <Spinner size="small" />;
    case "succeeded": return <StatusIcon kind="succeeded" size={16} />;
    case "failed": return <StatusIcon kind="failed" size={16} />;
    case "skipped": return <FilledGlyph kind="forward" tint="gray" />;
    case "stopped": return <FilledGlyph kind="stop" tint="gray" />;
  }
}

function RunRow(props: {
  run: HomeBackgroundRun;
  /** Older Macs send one shared activity instead of each run's own. */
  activity?: string;
  expanded: boolean;
  onToggle: () => void;
  canStop: boolean;
  inputs: InputRequest[];
  onAnswered: (request: InputRequest, decision: InputDecision) => void;
  focused: boolean;
}): JSX.Element {
  const { run, activity, expanded } = props;
  const [inputError, setInputError] = useState<string | null>(null);
  const running = runIsRunning(run);
  const result = runResult(run, activity);
  const shows = runShowsResult(run, activity);
  const canExpand = runCanExpand(run, activity);
  const resultID = `act-result-${run.id}`;
  const labelled = shows && !running && isLabelledSummary(result);
  return (
    <div class={`act-card${props.focused ? " focused" : ""}`} data-run-id={run.id} data-run-session={run.sessionID}>
      <span class="act-card-icon"><RunStatusIcon run={run} /></span>
      <div class="act-card-body">
        <div class={`act-run-summary-block${canExpand ? " expandable" : ""}`}
          onClick={canExpand ? (event) => {
            // Like the Mac, the whole summary toggles (the button below is the keyboard path).
            if ((event.target as HTMLElement).closest("a, button") || window.getSelection()?.toString()) return;
            props.onToggle();
          } : undefined}>
          <div class="act-run-label">{run.label}</div>
          <div class="act-run-detail">{runDetail(run, running ? now.value : halfMinute.value)}</div>
          {shows ? (
            labelled ? (
              <div id={resultID} class="act-run-summary selectable">
                {summaryLines(result).map((line, index) => {
                  const label = summaryLabel(line);
                  return (
                    <div key={index} class={`act-run-summary-line${expanded ? "" : " clamped"}`}>
                      {label ? <><strong>{label.label}</strong>{label.rest}</> : line}
                    </div>
                  );
                })}
              </div>
            ) : (
              <div id={resultID} class={`act-run-result selectable${expanded ? "" : " clamped"}`}>{inline(result, null, `run${run.id}`)}</div>
            )
          ) : null}
        </div>
        {canExpand ? (
          <button type="button" class="btn link act-expand" aria-expanded={expanded ? "true" : "false"} aria-controls={resultID}
            title={expanded ? "Collapses the result" : "Shows the full result"} onClick={props.onToggle}>
            <Icon name={expanded ? "chevron.up" : "chevron.down"} size={12} />
            {expanded ? "Show less" : "Show full result"}
          </button>
        ) : null}
        {run.handoffs?.length ? (
          <div class="act-handoffs">{run.handoffs.map((handoff) => <HandoffCard key={handoff.id} handoff={handoff} />)}</div>
        ) : null}
        {run.sessionID ? props.inputs.map((request) => (
          <div key={request.id} class="act-input-host" data-id="home.background.input">
            <InputCard request={request} sessionID={run.sessionID!} busy={remote.isMutating.value}
              onAnswered={(decision) => { setInputError(null); props.onAnswered(request, decision); }}
              onError={(message) => setInputError(`Your answer could not be delivered. ${message}`)} />
          </div>
        )) : null}
        {inputError ? <p class="alert-text" role="alert">{inputError}</p> : null}
        {props.inputs.length === 0 && runNeedsInput(run) ? (
          // Older Macs don't list the request; the live run shows it.
          <p class="act-footnote">Open this run to answer it. Update Cantrip on your Mac to answer here.</p>
        ) : null}
        {props.canStop ? (
          <div class="act-run-actions"><StopButton title="Stop" label={run.label} action={() => stopRun(run.id)} /></div>
        ) : null}
      </div>
    </div>
  );
}

// MARK: Sheet

export function BackgroundSheet(props: { focusSessionID?: string; onClose: () => void }): JSX.Element {
  const focus = props.focusSessionID;
  const [expanded, setExpanded] = useState<ReadonlySet<string>>(new Set());
  // Requests answered here, hidden until the Mac stops listing them.
  const [answered, setAnswered] = useState<ReadonlySet<string>>(new Set());
  const [announcement, setAnnouncement] = useState("");
  const contentRef = useRef<HTMLDivElement>(null);

  const selected = remote.selectedSession.value;
  const homeSessionID = selected?.isCantripHome ? selected.id : null;
  const homeDetail = homeSessionID ? remote.details.value.get(homeSessionID) : undefined;
  const watchers = homeSessionID ? backgroundSubagents(homeDetail?.messages) : [];
  const supportsRuns = selected?.supportsBackgroundRuns === true;
  const snapshot = supportsRuns ? remote.homeBackground.value : null;
  const hasRuns = Boolean(snapshot && (snapshot.runs.length || snapshot.queued.length));
  const canStop = snapshot?.supportsStop === true;
  const error = remote.homeBackgroundError.value;
  const waiting = needsInputRuns(snapshot);
  const others = otherRuns(snapshot);
  const runKey = snapshot?.runs.map((run) => run.id).join(",") ?? "";

  // GET /home/background every 2 s while a run waits on the user, else every 5 s, while open.
  useEffect(() => {
    let live = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const tick = async () => {
      if (!live) return;
      const session = remote.selectedSession.peek();
      if (!session) {
        timer = setTimeout(() => void tick(), 500);
        return;
      }
      if (session.isCantripHome && session.supportsBackgroundRuns === true) await remote.refreshBackground();
      if (live) timer = setTimeout(() => void tick(), backgroundPollDelay(remote.homeBackground.peek()));
    };
    void tick();
    return () => {
      live = false;
      if (timer) clearTimeout(timer);
    };
  }, []);

  // Show the run a notification or task pointed at (again whenever the list changes).
  useEffect(() => {
    if (!focus) return;
    const run = snapshot?.runs.find((item) => item.sessionID === focus);
    if (!run) return;
    const node = contentRef.current?.querySelector(`[data-run-id="${CSS.escape(run.id)}"]`);
    const reduce = matchMedia("(prefers-reduced-motion: reduce)").matches;
    node?.scrollIntoView({ block: "start", behavior: reduce ? "auto" : "smooth" });
  }, [focus, runKey]);

  const toggle = (id: string) => {
    const next = new Set(expanded);
    if (next.has(id)) next.delete(id);
    else next.add(id);
    setExpanded(next);
  };

  const onAnswered = (run: HomeBackgroundRun, request: InputRequest, decision: InputDecision) => {
    setAnswered((current) => new Set(current).add(request.id));
    setAnnouncement(`${answerResultText(decision)}. ${run.label} continues.`);
    void remote.refreshBackground();
  };

  const row = (run: HomeBackgroundRun, inputs: InputRequest[]) => (
    <RunRow key={run.id} run={run} activity={runIsRunning(run) ? snapshot?.activity : undefined}
      expanded={expanded.has(run.id)} onToggle={() => toggle(run.id)}
      canStop={canStop && run.canStop === true} inputs={inputs}
      onAnswered={(request, decision) => onAnswered(run, request, decision)}
      focused={Boolean(run.sessionID) && run.sessionID === focus} />
  );

  const body = () => {
    if (!watchers.length && !hasRuns && !error) {
      if (!selected || (supportsRuns && !snapshot)) {
        return <div class="act-loading"><Spinner size="large" /><span>Loading background work…</span></div>;
      }
      return (
        <div class="empty-state act-empty">
          <Icon name="gearshape.2" size={28} />
          <div class="title3">No background work</div>
          <p>{supportsRuns
            ? "Scheduled tasks, incident investigations and background watchers appear here."
            : "Background watchers appear here. Update Cantrip on your Mac to also see scheduled task and incident runs."}</p>
        </div>
      );
    }
    return (
      <div class="act-content act-background" ref={contentRef}>
        {waiting.length ? (
          <Section title="Needs your input">
            {waiting.map((run) => row(run, remainingInputs(run, answered)))}
          </Section>
        ) : null}
        {homeSessionID && watchers.length ? (
          <Section title="In this chat">
            <SubagentStack sessionID={homeSessionID} subagents={watchers} />
          </Section>
        ) : null}
        {snapshot?.queued.length ? (
          <Section title="Waiting">
            {snapshot.queued.map((item) => <QueuedRow key={item.id} item={item} canSkip={canStop} />)}
          </Section>
        ) : null}
        {others.length ? (
          <>
            <Section title="Scheduled and automated">
              {others.map((run) => row(run, []))}
            </Section>
            {snapshot?.maxParallel ? (
              <p class="act-footnote act-tight">
                Up to {snapshot.maxParallel} run at once, each in its own hidden session. Incidents in a project an open tab owns go to that tab.
              </p>
            ) : null}
          </>
        ) : null}
        {!supportsRuns ? <p class="act-footnote">Update Cantrip on your Mac to also see scheduled task and incident runs here.</p> : null}
        {error ? <WarningRow text={error} /> : null}
      </div>
    );
  };

  return (
    <Sheet title="Background" onClose={props.onClose} width={620} height={640} bodyClass="act-sheet-body"
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <DisconnectedNotice text="Disconnected. Showing the last known status." />
      <div class="sr-only" role="status" aria-live="polite">{announcement}</div>
      {body()}
    </Sheet>
  );
}
