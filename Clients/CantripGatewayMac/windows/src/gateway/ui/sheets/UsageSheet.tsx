// Usage Limits (CopilotUsageView, CopilotUsageView.swift): for Claude Code, Antigravity and Copilot, how
// much of each limit is used and when it resets. Re-read every 2 s while the Mac refreshes, else every 60 s.
import type { JSX } from "preact";
import { useSignal } from "@preact/signals";
import { api } from "../../api/client";
import type { AntigravityUsageState, ClaudeUsageState, CopilotUsageSnapshot } from "../../api/types";
import { FormSection, Sheet } from "../kit";
import { Caption, Loading, RefreshButton, StatusLabel, Warning, useAlive, usePolling, useTick } from "./common";
import {
  antigravityBucketTitle, antigravityBucketTone, antigravityBucketUsed, bucketTitle, claudeWindowTitle, claudeWindowTone,
  copilotBucketTone, copilotDate, errorText, formatDateTime, isAntigravityUsageStale, isClaudeUsageStale, isUnsupported,
  isUsageStale, usagePollDelay,
} from "./sheetLogic";

export function UsageSheet(props: { onClose: () => void }): JSX.Element | null {
  const snapshot = useSignal<CopilotUsageSnapshot | null>(null);
  const error = useSignal<string | null>(null);
  const loading = useSignal(false);
  const alive = useAlive();
  const now = useTick(30000);

  const refresh = async () => {
    if (loading.value) return;
    loading.value = true;
    try {
      const value = await api<CopilotUsageSnapshot>("/api/v1/copilot/usage");
      if (!alive.current) return;
      snapshot.value = value;
      error.value = null;
    } catch (failure) {
      if (!alive.current) return;
      error.value = isUnsupported(failure)
        ? "Update and reopen Cantrip on your Mac to view usage limits."
        : errorText(failure);
    } finally {
      loading.value = false;
    }
  };

  usePolling(async () => {
    await refresh();
    return usagePollDelay(snapshot.value);
  });

  const value = snapshot.value;
  const account = value?.account;
  const refreshing = loading.value || value?.isRefreshing === true;

  return (
    <Sheet title="Usage Limits" onClose={props.onClose}
      leading={<RefreshButton label="Refresh usage limits" disabled={refreshing} onClick={() => void refresh()} />}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      {refreshing || error.value ? (
        <FormSection>
          <div class="form-row">
            <div class="sh-stack grow">
              {refreshing ? <Loading text="Reading usage limits..." /> : null}
              {error.value ? <Warning>{error.value}</Warning> : null}
            </div>
          </div>
        </FormSection>
      ) : null}
      {value?.claude ? <ClaudeSection state={value.claude} now={now} /> : null}
      {value?.antigravity ? <AntigravitySection state={value.antigravity} now={now} /> : null}
      {value ? (
        <FormSection header="Copilot">
          <div class="form-row">
            <div class="sh-stack wide grow selectable">
              {value.error ? <Warning>{value.error}</Warning> : null}
              {account && (error.value !== null || isUsageStale(value, now))
                ? <StatusLabel icon="clock" tone="warning">Last known limits - data is stale</StatusLabel> : null}
              {!account && !value.error && !refreshing ? <span class="muted">Copilot's limits unavailable</span> : null}
              {(account?.buckets ?? []).map((bucket) => (
                <LimitRow key={bucket.id} title={bucketTitle(bucket)}
                  used={bucket.isUnlimited ? null : 100 - (bucket.remainingPercent ?? 100)}
                  resetsAt={bucket.isUnlimited ? undefined : bucket.resetAt}
                  tone={bucket.isUnlimited ? "normal" : copilotBucketTone(bucket)} />
              ))}
            </div>
          </div>
        </FormSection>
      ) : null}
    </Sheet>
  );
}

/** UsageLimitRow: one limit's use and reset, nothing else. `used` is null for an unlimited allowance. */
function LimitRow(props: { title: string; used: number | null; resetsAt?: string; tone: "normal" | "warning" | "critical" }): JSX.Element {
  const { title, tone } = props;
  const used = props.used === null ? null : Math.min(100, Math.max(0, props.used));
  const reset = copilotDate(props.resetsAt);
  return (
    <div class="sh-stack">
      <div class="headline">{title} · {used === null ? "Unlimited" : `${used.toFixed(0)}% used`}</div>
      {used !== null ? (
        <div class={`sh-meter${tone === "normal" ? "" : " low"}`} role="progressbar" aria-label={title}
          aria-valuemin={0} aria-valuemax={100} aria-valuenow={used} aria-valuetext={`${used.toFixed(0)}%`}>
          <div style={{ width: `${used}%` }} />
        </div>
      ) : null}
      {reset ? <Caption>Resets {formatDateTime(reset)}</Caption> : null}
    </div>
  );
}

/** ClaudeUsageSection: Claude Code's 5-hour and weekly limits, as the Mac reads them from Claude. */
function ClaudeSection(props: { state: ClaudeUsageState; now: number }): JSX.Element {
  const { state, now } = props;
  const account = state.account;
  return (
    <FormSection header="Claude Code">
      <div class="form-row">
        <div class="sh-stack wide grow selectable">
          {state.error ? <Warning>{state.error}</Warning> : null}
          {account && isClaudeUsageStale(state, now)
            ? <StatusLabel icon="clock" tone="warning">Last known limits - data is stale</StatusLabel> : null}
          {!account && !state.error ? <span class="muted">Claude's limits unavailable</span> : null}
          {(account?.windows ?? []).map((window) => (
            <LimitRow key={window.id} title={claudeWindowTitle(window)} used={window.percentUsed}
              resetsAt={window.resetsAt} tone={claudeWindowTone(window)} />
          ))}
        </div>
      </div>
    </FormSection>
  );
}

/** AntigravityUsageSection: Antigravity's weekly and 5-hour limits per model group, as the Mac reads them from agy. */
function AntigravitySection(props: { state: AntigravityUsageState; now: number }): JSX.Element {
  const { state, now } = props;
  const groups = state.account?.groups ?? [];
  if (!groups.length) {
    return (
      <FormSection header="Antigravity">
        <div class="form-row">
          {state.error ? <Warning>{state.error}</Warning> : <span class="muted">Antigravity's limits unavailable</span>}
        </div>
      </FormSection>
    );
  }
  return (
    <>
      {groups.map((group, index) => (
        <FormSection key={group.name} header={`Antigravity · ${group.name}`}>
          <div class="form-row">
            <div class="sh-stack wide grow selectable">
              {index === 0 && state.error ? <Warning>{state.error}</Warning> : null}
              {index === 0 && isAntigravityUsageStale(state, now)
                ? <StatusLabel icon="clock" tone="warning">Last known limits - data is stale</StatusLabel> : null}
              {group.buckets.map((bucket) => (
                <LimitRow key={bucket.id} title={antigravityBucketTitle(bucket)} used={antigravityBucketUsed(bucket)}
                  resetsAt={bucket.resetsAt} tone={antigravityBucketTone(bucket)} />
              ))}
            </div>
          </div>
        </FormSection>
      ))}
    </>
  );
}
