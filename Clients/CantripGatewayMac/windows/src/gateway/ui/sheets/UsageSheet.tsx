// Usage Limits (CopilotUsageView + ClaudeUsageSection + AntigravityUsageSection, CopilotUsageView.swift):
// Claude Code's and Antigravity's limits and the Copilot account signed in on the Mac. Re-read every 2 s while the Mac refreshes, else every 60 s.
import type { JSX } from "preact";
import { useSignal } from "@preact/signals";
import { api } from "../../api/client";
import type { AntigravityUsageState, ClaudeUsageState, CopilotQuotaBucket, CopilotUsageSnapshot } from "../../api/types";
import { FormRow, FormSection, Sheet } from "../kit";
import { Caption, Loading, RefreshButton, StatusLabel, Warning, useAlive, usePolling, useTick } from "./common";
import {
  antigravityBucketTitle, antigravityBucketTone, antigravityBucketUsed, billingText, bucketSummary, bucketTitle,
  claudeWindowTitle, claudeWindowTone, copilotDate, errorText, formatDateTime, isAntigravityUsageStale,
  isClaudeUsageStale, isUnsupported, isUsageStale, overageAllowedText, overageText, percentageSummary, usagePollDelay,
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
  const problem = error.value ?? value?.error ?? null;
  const checked = copilotDate(value?.checkedAt);

  return (
    <Sheet title="Usage Limits" onClose={props.onClose}
      leading={<RefreshButton label="Refresh usage limits" disabled={refreshing} onClick={() => void refresh()} />}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <FormSection>
        <div class="form-row">
          <div class="sh-stack grow">
            {refreshing ? <Loading text="Reading Copilot account allowance..." /> : null}
            {problem ? <Warning>{problem}</Warning> : null}
            {value && account && (error.value !== null || isUsageStale(value, now))
              ? <StatusLabel icon="clock" tone="warning">Last known allowance - data is stale</StatusLabel>
              : null}
            {!account && !refreshing ? <span class="muted">Account allowance unavailable</span> : null}
            <Caption>The Copilot account signed in on your Cantrip Mac. This is account-wide, not just this conversation, and remains available from any chat lane.</Caption>
          </div>
        </div>
      </FormSection>
      {value?.claude ? <ClaudeSection state={value.claude} now={now} /> : null}
      {value?.antigravity ? <AntigravitySection state={value.antigravity} now={now} /> : null}
      {account ? (
        <>
          {account.login !== undefined || account.plan !== undefined || checked ? (
            <FormSection header="Copilot account">
              {account.login !== undefined ? <FormRow label="Account"><span class="sh-value selectable">{account.login}</span></FormRow> : null}
              {account.plan !== undefined ? <FormRow label="Plan"><span class="sh-value">{account.plan}</span></FormRow> : null}
              {checked ? <FormRow label="Checked"><span class="sh-value">{formatDateTime(checked)}</span></FormRow> : null}
            </FormSection>
          ) : null}
          {account.buckets.map((bucket) => (
            <FormSection key={bucket.id} header={bucketTitle(bucket)}>
              <div class="form-row"><QuotaRow bucket={bucket} /></div>
            </FormSection>
          ))}
        </>
      ) : null}
      <FormSection>
        <div class="form-row">
          <div class="sh-stack grow">
            <Caption>The Mac refreshes every five minutes, and at most once a minute when you ask. No prompts are sent and no model is invoked. Credentials stay on the Mac.</Caption>
            <Caption>Remaining account allowance does not rule out model-specific or short-term rate limits.</Caption>
          </div>
        </div>
      </FormSection>
    </Sheet>
  );
}

/** ClaudeUsageSection: Claude Code's 5-hour and weekly limits, as the Mac reads them from Claude. */
function ClaudeSection(props: { state: ClaudeUsageState; now: number }): JSX.Element {
  const { state, now } = props;
  const account = state.account;
  const checked = copilotDate(state.checkedAt);
  const plan = account?.plan;
  return (
    <FormSection header={plan ? `Claude Code · ${plan.charAt(0).toUpperCase()}${plan.slice(1)}` : "Claude Code"}>
      <div class="form-row">
        <div class="sh-stack wide grow selectable">
          {state.error ? <Warning>{state.error}</Warning> : null}
          {account && isClaudeUsageStale(state, now)
            ? <StatusLabel icon="clock" tone="warning">Last known limits - data is stale</StatusLabel> : null}
          {!account && !state.error ? <span class="muted">Claude's limits unavailable</span> : null}
          {(account?.windows ?? []).map((window) => {
            const used = Math.min(100, Math.max(0, window.percentUsed));
            const tone = claudeWindowTone(window);
            const reset = copilotDate(window.resetsAt);
            return (
              <div key={window.id} class="sh-stack">
                <div class="headline">{claudeWindowTitle(window)} · {used.toFixed(0)}% used</div>
                <div class={`sh-meter${tone === "normal" ? "" : " low"}`} role="progressbar"
                  aria-label={claudeWindowTitle(window)} aria-valuemin={0} aria-valuemax={100} aria-valuenow={used}
                  aria-valuetext={`${used.toFixed(0)}%`}>
                  <div style={{ width: `${used}%` }} />
                </div>
                {reset ? <Caption>Resets {formatDateTime(reset)}</Caption> : null}
              </div>
            );
          })}
          {checked ? <Caption>Checked {formatDateTime(checked)}</Caption> : null}
        </div>
      </div>
    </FormSection>
  );
}

/** AntigravityUsageSection: Antigravity's weekly and 5-hour limits per model group, as the Mac reads them from agy. */
function AntigravitySection(props: { state: AntigravityUsageState; now: number }): JSX.Element {
  const { state, now } = props;
  const groups = state.account?.groups ?? [];
  const checked = copilotDate(state.checkedAt);
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
              {group.buckets.map((bucket) => {
                const used = antigravityBucketUsed(bucket);
                const tone = antigravityBucketTone(bucket);
                const reset = copilotDate(bucket.resetsAt);
                return (
                  <div key={bucket.id} class="sh-stack">
                    <div class="headline">{antigravityBucketTitle(bucket)} · {used.toFixed(0)}% used</div>
                    <div class={`sh-meter${tone === "normal" ? "" : " low"}`} role="progressbar"
                      aria-label={`${group.name}, ${antigravityBucketTitle(bucket)}`} aria-valuemin={0} aria-valuemax={100}
                      aria-valuenow={used} aria-valuetext={`${used.toFixed(0)}%`}>
                      <div style={{ width: `${used}%` }} />
                    </div>
                    {reset ? <Caption>Resets {formatDateTime(reset)}</Caption> : null}
                  </div>
                );
              })}
              {group.models ? <Caption>{group.models}</Caption> : null}
              {index === groups.length - 1 && checked ? <Caption>Checked {formatDateTime(checked)}</Caption> : null}
            </div>
          </div>
        </FormSection>
      ))}
    </>
  );
}

/** CopilotQuotaRow. */
function QuotaRow(props: { bucket: CopilotQuotaBucket }): JSX.Element {
  const { bucket } = props;
  const remaining = bucket.remainingPercent;
  const percentage = percentageSummary(bucket);
  const used = remaining !== undefined ? Math.min(100, Math.max(0, 100 - remaining)) : 0;
  const reset = copilotDate(bucket.resetAt);
  const observed = copilotDate(bucket.observedAt);
  const overage = overageText(bucket);
  return (
    <div class="sh-stack wide grow selectable">
      <div class="headline">{bucketSummary(bucket)}</div>
      {!bucket.isUnlimited && remaining !== undefined && percentage ? (
        <>
          <div class={`sh-meter${remaining <= 10 ? " low" : ""}`} role="progressbar" aria-label="Included allowance used"
            aria-valuemin={0} aria-valuemax={100} aria-valuenow={used} aria-valuetext={`${(100 - remaining).toFixed(1)}%`}>
            <div style={{ width: `${used}%` }} />
          </div>
          <Caption>{percentage}</Caption>
        </>
      ) : null}
      <Caption>{billingText(bucket)}</Caption>
      <div>{overageAllowedText(bucket)}</div>
      {overage ? <div class="sh-subheadline">{overage}</div> : null}
      {reset
        ? <div>Resets {formatDateTime(reset)} (local time)</div>
        : <div class="muted">Reset date unavailable</div>}
      {observed ? <Caption>Source snapshot: {formatDateTime(observed)}</Caption> : null}
    </div>
  );
}
