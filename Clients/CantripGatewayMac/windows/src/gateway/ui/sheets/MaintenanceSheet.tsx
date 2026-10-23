// Update Cantrip (CantripMaintenanceSheet / CantripMaintenanceView): check, update, rebuild or restart
// Cantrip on the Mac. Each request carries a client ID and the status revision; an unconfirmed request
// is saved so a retry reuses its ID (the Mac treats it as the same request). Re-read every 3 s while a
// job runs or a request awaits its receipt, else every 15 s.
import type { JSX } from "preact";
import { batch, useSignal } from "@preact/signals";
import { useMemo } from "preact/hooks";
import { api } from "../../api/client";
import type { MaintenanceAction, MaintenanceRequest, MaintenanceSnapshot } from "../../api/types";
import { MAINTENANCE_ACTIONS } from "../../api/types";
import { now } from "../../state/clock";
import { appleDate } from "../../state/format";
import * as remote from "../../state/remote";
import { FormRow, FormSection, Sheet, confirmDialog } from "../kit";
import { Caption, Loading, StatusLabel, Warning, useAlive, usePolling } from "./common";
import {
  MAINTENANCE_ACTION_INFO, NotSentError, busySessionsText, canStartMaintenance, clearsPendingMaintenance, endpointHost, errorText,
  isMaintenanceRequest, isUnsupported, maintenanceJobRunning, maintenancePollDelay, relativeDuration,
} from "./sheetLogic";

function readPending(key: string): { pending: MaintenanceRequest | null; error: string | null } {
  try {
    const raw = localStorage.getItem(key);
    if (raw === null) return { pending: null, error: null };
    const value: unknown = JSON.parse(raw);
    if (!isMaintenanceRequest(value)) throw new Error("The saved request is not valid.");
    return { pending: value, error: null };
  } catch (failure) {
    return { pending: null, error: `Could not recover the previous maintenance request. ${errorText(failure)}` };
  }
}

function maintenanceError(failure: unknown): string {
  return isUnsupported(failure)
    ? "Update and reopen Cantrip on the Mac once to enable remote updates and rebuilds."
    : errorText(failure);
}

export function MaintenanceSheet(props: { onClose: () => void }): JSX.Element | null {
  const status = remote.hostStatus.value;
  // One saved request per paired Mac (CantripMaintenanceModel's pendingKey).
  const pendingKey = useMemo(() => `cantrip.maintenance.pending.${status.server || "unconfigured"}`, []);
  const recovered = useMemo(() => readPending(pendingKey), []);
  const snapshot = useSignal<MaintenanceSnapshot | null>(null);
  const error = useSignal<string | null>(recovered.error);
  const isRequesting = useSignal(false);
  const pending = useSignal<MaintenanceRequest | null>(recovered.pending);
  const alive = useAlive();

  const clearPending = () => {
    pending.value = null;
    try { localStorage.removeItem(pendingKey); } catch { /* storage unavailable */ }
  };

  const apply = (value: MaintenanceSnapshot) => {
    snapshot.value = value;
    if (pending.value && value.acceptedRequestIDs.includes(pending.value.id)) clearPending();
  };

  const refresh = async () => {
    if (isRequesting.value) return;
    isRequesting.value = true;
    try {
      const value = await api<MaintenanceSnapshot>("/api/v1/maintenance");
      if (!alive.current) return;
      batch(() => {
        apply(value);
        error.value = null;
      });
    } catch (failure) {
      if (alive.current) error.value = maintenanceError(failure);
    } finally {
      isRequesting.value = false;
    }
  };

  const submit = async (action: MaintenanceAction) => {
    if (isRequesting.value) return;
    if (pending.value && pending.value.action !== action) {
      error.value = "Refresh or retry the pending request before starting another action.";
      return;
    }
    isRequesting.value = true;
    try {
      const revision = pending.value?.revision ?? snapshot.value?.revision;
      if (!revision) throw new NotSentError("Refresh the Mac's maintenance status first.");
      const request: MaintenanceRequest = pending.value ?? { id: crypto.randomUUID().toUpperCase(), action, revision };
      localStorage.setItem(pendingKey, JSON.stringify(request));
      pending.value = request;
      const value = await api<MaintenanceSnapshot>("/api/v1/maintenance", { method: "POST", body: request });
      if (!alive.current) return;
      batch(() => {
        apply(value);
        error.value = null;
      });
    } catch (failure) {
      // A definite rejection clears the request; an uncertain one keeps its ID for a safe retry.
      if (clearsPendingMaintenance(failure)) clearPending();
      if (alive.current) error.value = maintenanceError(failure);
    } finally {
      isRequesting.value = false;
    }
  };

  const choose = async (action: MaintenanceAction) => {
    if (action === "check") {
      await submit(action);
      return;
    }
    const info = MAINTENANCE_ACTION_INFO[action];
    const confirmed = await confirmDialog({ title: info.title, message: info.detail, confirm: info.title, destructive: action === "restart" });
    if (confirmed && alive.current) await submit(action);
  };

  usePolling(async () => {
    await refresh();
    return maintenancePollDelay(snapshot.value, pending.value);
  });

  const value = snapshot.value;
  const job = value?.job;
  const state = { snapshot: value, isRequesting: isRequesting.value, pending: pending.value, error: error.value };
  const waiting = pending.value;

  return (
    <Sheet title="Update Cantrip" onClose={props.onClose}
      footer={<button type="button" class="btn primary" onClick={props.onClose}>Done</button>}>
      <FormSection header="Connected Mac">
        <FormRow><span class="selectable">{endpointHost(status.route, status.server)}</span></FormRow>
        {value ? (
          <>
            <FormRow label="Running build"><span class="sh-value selectable">{value.runningBuild}</span></FormRow>
            {value.installedBuild !== undefined ? (
              <>
                <FormRow label="Installed build"><span class="sh-value selectable">{value.installedBuild}</span></FormRow>
                {value.installedBuild !== value.runningBuild
                  ? <FormRow><Caption>A different build is installed. Restart to activate it.</Caption></FormRow>
                  : null}
              </>
            ) : null}
            {value.branch !== undefined
              ? <FormRow label="Branch"><span class="sh-value selectable">{value.branch === "" ? "Detached HEAD" : value.branch}</span></FormRow>
              : null}
            {value.commitsBehind !== undefined
              ? <FormRow label="Newer commits"><span class="sh-value">{value.commitsBehind}</span></FormRow>
              : null}
            {value.checkedAt !== undefined
              ? <FormRow label="Last checked"><span class="sh-value">{relativeDuration(appleDate(value.checkedAt), now.value)}</span></FormRow>
              : null}
            {value.localChanges === true ? (
              <FormRow>
                <StatusLabel icon="pencil">Local changes on the Mac. Update is blocked; rebuilding keeps those edits.</StatusLabel>
              </FormRow>
            ) : null}
            {value.busySessions > 0
              ? <FormRow><StatusLabel icon="hourglass">{busySessionsText(value.busySessions)}</StatusLabel></FormRow>
              : null}
            {value.unavailableReason !== undefined
              ? <FormRow><Warning>{value.unavailableReason}</Warning></FormRow>
              : null}
          </>
        ) : null}
      </FormSection>
      <FormSection class="sh-actions-list"
        footer="Operations run on the Mac, even if you close Cantrip Gateway. Building never automatically restarts Cantrip or stops a tab. This does not update Cantrip Gateway on this PC.">
        {MAINTENANCE_ACTIONS.map((action) => (
          <FormRow key={action}>
            <button type="button" class="btn"
              disabled={!canStartMaintenance(action, state) || remote.isMutating.value}
              title={MAINTENANCE_ACTION_INFO[action].detail}
              onClick={() => void choose(action)}>
              {MAINTENANCE_ACTION_INFO[action].title}
            </button>
          </FormRow>
        ))}
      </FormSection>
      {job ? (
        <FormSection header="Latest operation">
          <FormRow>
            {maintenanceJobRunning(job)
              ? <Loading text={job.message} />
              : (
                <StatusLabel icon={job.phase === "failed" ? "exclamationmark.triangle" : "checkmark.circle"}
                  tone={job.phase === "failed" ? "warning" : undefined} role="status">
                  {job.message}
                </StatusLabel>
              )}
          </FormRow>
          {job.output !== "" ? (
            <FormRow>
              <details class="sh-output grow">
                <summary>Build output (latest)</summary>
                <pre class="sh-pre" tabIndex={0}>{job.output}</pre>
              </details>
            </FormRow>
          ) : null}
        </FormSection>
      ) : null}
      <FormSection>
        {error.value ? (
          <FormRow>
            <div class="sh-stack grow">
              <Warning>{error.value}</Warning>
              {value ? <Caption>Showing the last received status.</Caption> : null}
            </div>
          </FormRow>
        ) : null}
        {waiting ? (
          <FormRow>
            <div class="sh-stack grow">
              <Caption class="sh-footnote">
                The Mac may have accepted {MAINTENANCE_ACTION_INFO[waiting.action].title}. Refresh to recover its status, or retry the same request safely.
              </Caption>
              <div>
                <button type="button" class="btn" disabled={isRequesting.value} onClick={() => void submit(waiting.action)}>
                  Retry Pending Request
                </button>
              </div>
            </div>
          </FormRow>
        ) : null}
        <FormRow>
          <button type="button" class="btn" disabled={isRequesting.value} onClick={() => void refresh()}>Refresh Status</button>
        </FormRow>
        {isRequesting.value ? <FormRow><Loading text="Contacting Mac..." /></FormRow> : null}
      </FormSection>
    </Sheet>
  );
}
