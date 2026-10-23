// Secure Input (CantripInputRequestsView in CantripInputRequests.swift): passwords and passphrases a
// waiting program on the Mac asked for. Questions and approvals are answered in chat instead.
import "./activity.css";
import type { JSX } from "preact";
import { useEffect, useRef, useState } from "preact/hooks";
import { api, pathComponent } from "../../api/client";
import type { InputRequest, InputRequestsResponse } from "../../api/types";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Sheet, Spinner } from "../kit";
import { InputCard } from "../transcript/Inputs";

export function InputRequestsSheet(props: { sessionID: string; onClose: () => void }): JSX.Element {
  const { sessionID } = props;
  const [requests, setRequests] = useState<InputRequest[]>([]);
  const [error, setError] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const submitting = remote.isMutating.value;
  const live = useRef(true);
  const session = remote.details.value.get(sessionID)
    ?? (sessionID === remote.homeID.value ? remote.homeSummary.value : remote.sessions.value.find((item) => item.id === sessionID));

  const load = async () => {
    try {
      const data = await api<InputRequestsResponse>(`/api/v1/sessions/${pathComponent(sessionID)}/input`);
      if (!live.current) return;
      setRequests(data.requests.filter((request) => request.kind === "secret"));
    } catch (failure) {
      if (live.current) setError((failure as Error).message);
    }
    if (live.current) setLoading(false);
  };

  // Load now, then every 2 s while open (skipped while an answer is on its way or the window is hidden).
  useEffect(() => {
    live.current = true;
    let timer: ReturnType<typeof setTimeout> | null = null;
    const tick = async () => {
      if (!live.current) return;
      if (!remote.isMutating.peek() && document.visibilityState !== "hidden") await load();
      if (live.current) timer = setTimeout(() => void tick(), 2000);
    };
    void load().then(() => { if (live.current) timer = setTimeout(() => void tick(), 2000); });
    return () => {
      live.current = false;
      if (timer) clearTimeout(timer);
    };
  }, [sessionID]);

  return (
    <Sheet title="Secure Input" onClose={props.onClose} width={600} height={600} locked={submitting}
      actions={<button type="button" class="btn small" disabled={submitting} onClick={() => void load()}>Reload</button>}
      footer={<button type="button" class="btn primary" disabled={submitting} onClick={props.onClose}>Done</button>}>
      <div class="act-content act-inputs">
        <div class="headline">{remote.tabTitle(session)}</div>
        <p class="act-footnote">Use this secure form only for passwords and passphrases. Questions and approvals appear in chat.</p>
        <button type="button" class="btn link act-link" onClick={() => { nav.sheet.value = { kind: "macAccess" }; }}>
          Mac Permissions &amp; View Mac
        </button>
        {loading ? <div class="row muted"><Spinner label="Loading pending requests" /><span>Loading pending requests...</span></div> : null}
        {error ? <p class="act-warning" role="alert" data-id="cantrip.input.error">{error}</p> : null}
        {!loading && !requests.length ? <p class="act-line" role="status">No password is pending. Return to chat for questions and other actions.</p> : null}
        {requests.map((request) => (
          <InputCard key={request.id} request={request} sessionID={sessionID} busy={submitting}
            onAnswered={() => {
              setRequests((current) => current.filter((item) => item.id !== request.id));
              setError(null);
              void load();
            }} />
        ))}
      </div>
    </Sheet>
  );
}
