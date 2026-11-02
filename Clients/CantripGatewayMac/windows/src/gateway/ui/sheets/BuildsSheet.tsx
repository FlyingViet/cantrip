// GitHub Builds (GitHubBuildsView.swift): read-only builds and runners across the user's apps. Re-read every
// 3 s while the Mac refreshes GitHub, else every 10 s. One estimated queue across all apps.
import type { JSX } from "preact";
import { useSignal } from "@preact/signals";
import { api } from "../../api/client";
import type { GitHubBuildRepository, GitHubBuildSnapshot } from "../../api/types";
import { bridge } from "../../bridge";
import { now } from "../../state/clock";
import { Icon } from "../icons";
import { FormSection, Sheet } from "../kit";
import { Caption, Loading, RefreshButton, StatusLabel, Warning, useAlive, usePolling } from "./common";
import {
  assignmentText, buildEntries, buildQueue, buildsPollDelay, copilotDate, errorText, githubURL, isUnsupported, jobIsRunning,
  jobStatusTitle, queueReason, relativeDuration, repositoryCheckedDate, repositoryIsStale, runnerStatusText, snapshotIsComplete,
  type BuildEntry,
} from "./sheetLogic";

export function BuildsSheet(props: { onClose: () => void }): JSX.Element | null {
  const snapshot = useSignal<GitHubBuildSnapshot | null>(null);
  const error = useSignal<string | null>(null);
  const loading = useSignal(false);
  const alive = useAlive();

  const refresh = async () => {
    if (loading.value) return;
    loading.value = true;
    try {
      const value = await api<GitHubBuildSnapshot>("/api/v1/github/builds");
      if (!alive.current) return;
      snapshot.value = value;
      error.value = null;
    } catch (failure) {
      if (!alive.current) return;
      error.value = isUnsupported(failure) ? "Update and reopen Cantrip on your Mac to view GitHub builds." : errorText(failure);
    } finally {
      loading.value = false;
    }
  };

  usePolling(async () => {
    await refresh();
    return buildsPollDelay(snapshot.value);
  });

  const time = now.value;
  const value = snapshot.value;
  const problem = error.value ?? value?.error ?? null;
  const entries = value ? buildEntries(value) : [];
  const running = entries.filter((entry) => jobIsRunning(entry.job));

  return (
    <Sheet title="GitHub Builds" onClose={props.onClose} width={720} height={680}
      leading={<RefreshButton label="Refresh GitHub builds" disabled={loading.value} onClick={() => void refresh()} />}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <FormSection>
        <div class="form-row">
          <div class="sh-stack grow">
            {loading.value || value?.isRefreshing ? <Loading text="Checking GitHub builds..." /> : null}
            {problem ? (
              <>
                <Warning>{problem}</Warning>
                {value ? <Caption>Showing the last snapshot; build and runner states may be out of date.</Caption> : null}
              </>
            ) : null}
            <Caption>Read-only view across your apps. The Mac checks GitHub at most once a minute while this screen is open.</Caption>
          </div>
        </div>
      </FormSection>
      {value ? (
        <>
          {running.length ? (
            <FormSection header={`Building now (${running.length})`}>
              {running.map((entry) => <div key={entry.job.id} class="form-row"><BuildRow entry={entry} now={time} /></div>)}
            </FormSection>
          ) : null}
          <QueueSection snapshot={value} hasLoadError={error.value !== null} now={time} />
          {entries.length === 0 && snapshotIsComplete(value, time) && error.value === null
            && !value.repositories.some((repository) => repository.busy) ? (
              <FormSection>
                <div class="form-row">
                  <div class="sh-stack grow">
                    <StatusLabel icon="checkmark.circle">No active builds reported</StatusLabel>
                    <Caption>None of the monitored runners have running or queued jobs in the latest snapshot.</Caption>
                  </div>
                </div>
              </FormSection>
            ) : null}
          {value.repositories.length ? (
            <FormSection header="Runners">
              {value.repositories.map((repository) => (
                <div key={repository.repository} class="form-row"><RunnerRow repository={repository} now={time} /></div>
              ))}
            </FormSection>
          ) : null}
        </>
      ) : null}
    </Sheet>
  );
}

/** GitHubBuildQueueSection. */
function QueueSection(props: { snapshot: GitHubBuildSnapshot; hasLoadError: boolean; now: number }): JSX.Element {
  const queue = buildQueue(props.snapshot, !props.hasLoadError, props.now);
  const complete = snapshotIsComplete(props.snapshot, props.now) && !props.hasLoadError;
  return (
    <FormSection header={`Build queue (${queue.length})`}
      footer="One queue across all apps. Estimated order: available runners, busy runners, then other waits; oldest workflow first within each group. Numbers are estimated positions, not GitHub scheduling guarantees. Separate runners can start in parallel.">
      {!complete ? (
        <div class="form-row">
          <StatusLabel icon="exclamationmark.triangle" tone="warning" class="caption">
            Queue may be incomplete or out of date. Up next is unavailable.
          </StatusLabel>
        </div>
      ) : null}
      {queue.length === 0 ? (
        <div class="form-row">
          <span class="sh-subheadline muted">{complete ? "No queued builds reported across your apps." : "Waiting for a complete queue snapshot."}</span>
        </div>
      ) : (
        <>
          {complete && !queue.some((item) => item.isUpNext) ? (
            <div class="form-row">
              <Caption>Up next is unknown until a runner is online and GitHub releases eligible work.</Caption>
            </div>
          ) : null}
          {queue.map((item) => (
            <div key={item.entry.job.id} class="form-row">
              <BuildRow entry={item.entry} position={item.position} upNext={item.isUpNext} now={props.now} />
            </div>
          ))}
        </>
      )}
    </FormSection>
  );
}

/** GitHubBuildRow. */
function BuildRow(props: { entry: BuildEntry; position?: number; upNext?: boolean; now: number }): JSX.Element {
  const { entry, now: time } = props;
  const { job, repository } = entry;
  const isRunning = jobIsRunning(job);
  const started = copilotDate(isRunning ? job.startedAt : job.createdAt);
  const link = githubURL(entry);
  return (
    <div class="sh-build grow selectable">
      {props.position !== undefined ? (
        <div class="sh-position">
          <strong class="sh-subheadline" aria-label={`Estimated queue position ${props.position}`}>#{props.position}</strong>
          {props.upNext ? <span class="sh-subheadline sh-accent sh-headline">Up next (estimated)</span> : null}
        </div>
      ) : null}
      <span class="headline">{repository.app}</span>
      <StatusLabel icon={isRunning ? "hammer" : "clock"} tone={isRunning ? "accent" : "secondary"} class="sh-status">
        {jobStatusTitle(job)}
      </StatusLabel>
      {props.position !== undefined ? <Caption>{queueReason(entry, time)}</Caption> : null}
      {repositoryIsStale(repository, time)
        ? <StatusLabel icon="exclamationmark.triangle" tone="warning" class="caption">Last known state - data is stale</StatusLabel>
        : null}
      <span class="sh-subheadline">{job.workflow} #{job.number} - attempt {job.attempt}</span>
      <span class="sh-subheadline sh-medium">{job.job}</span>
      {job.step !== undefined ? <span class="sh-subheadline">Current step: {job.step}</span> : null}
      {job.title !== job.workflow ? <Caption>{job.title}</Caption> : null}
      <span class="caption sh-mono muted">{job.branch} - {job.commit.slice(0, 7)}</span>
      <Caption>{assignmentText(entry)}</Caption>
      {started ? <Caption>{isRunning ? "Started" : "Workflow created"} {relativeDuration(started, time)} ago</Caption> : null}
      {link ? (
        <div>
          <a class="sh-subheadline sh-label" href={link} onClick={(event) => { event.preventDefault(); bridge.openExternal(link); }}>
            <Icon name="arrow.up.forward.square" size={14} />
            <span>Open in GitHub</span>
          </a>
        </div>
      ) : null}
    </div>
  );
}

function RunnerRow(props: { repository: GitHubBuildRepository; now: number }): JSX.Element {
  const { repository, now: time } = props;
  const stale = repositoryIsStale(repository, time);
  const checked = repositoryCheckedDate(repository);
  return (
    <div class="sh-build grow selectable">
      <span class="headline">{repository.app}</span>
      <span class="sh-subheadline">{repository.runner}</span>
      <Caption>{repository.repository}</Caption>
      <StatusLabel icon={stale ? "exclamationmark.triangle" : "desktopcomputer"}
        tone={stale || repository.runnerStatus !== "online" ? "warning" : "secondary"} class="caption">
        {runnerStatusText(repository, time)}
      </StatusLabel>
      {repository.warning !== undefined ? <Caption class="sh-warning">{repository.warning}</Caption> : null}
      {repository.busy && !repository.jobs.some(jobIsRunning) && !stale
        ? <Caption>Runner reports busy; GitHub has not reported a matching running job yet.</Caption>
        : null}
      {checked ? <span class="sh-caption2">Checked {relativeDuration(checked, time)} ago</span> : null}
    </div>
  );
}
