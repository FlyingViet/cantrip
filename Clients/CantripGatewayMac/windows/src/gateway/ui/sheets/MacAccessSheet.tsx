// Mac Access (CantripMacAccessView + CantripDesktopModel, CantripMacAccess.swift): the Mac's permission
// status with "Open … on Mac" buttons, and View Mac: a five-minute lease whose JPEG frames (about one a
// second) and pointer/keyboard input are AES-256-GCM sealed with the lease key, bound by additional data
// to the lease, frame, display and input sequence. Viewing stops when the sheet closes or the window hides.
import type { JSX } from "preact";
import { batch, useSignal } from "@preact/signals";
import { useEffect, useId, useRef, useState } from "preact/hooks";
import { api } from "../../api/client";
import type {
  AcceptedResponse, DesktopCommand, DesktopCommandKind, DesktopFrame, DesktopLease, DesktopStopResponse, MacAccessSnapshot,
  MacPermission, OpenMacSettingsResponse,
} from "../../api/types";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { Sheet, confirmDialog } from "../kit";
import { Caption, Loading, StatusLabel, sleep, useAlive } from "./common";
import {
  DESKTOP_KEY_BUTTONS, DESKTOP_TEXT_LIMIT, InvalidResponseError, capitalized, decryptDesktopFrame, encryptDesktopCommand,
  errorText, importDesktopKey, isUnsupported, normalizedPoint, permissionStateLabel, utf8Length, writeFailure,
} from "./sheetLogic";

const CONTROL_KEY = "cantrip.desktop.control";

function savedControl(): boolean {
  try { return localStorage.getItem(CONTROL_KEY) === "true"; } catch { return false; }
}

async function fetchAccess(): Promise<MacAccessSnapshot> {
  try {
    return await api<MacAccessSnapshot>("/api/v1/mac-access");
  } catch (failure) {
    if (isUnsupported(failure)) throw new Error("Update and reopen Cantrip on the Mac to enable Mac Permissions & View Mac.");
    throw failure;
  }
}

/** A decoded JPEG as an object URL (rejects bytes that aren't an image). */
async function jpegURL(bytes: Uint8Array<ArrayBuffer>): Promise<string> {
  const url = URL.createObjectURL(new Blob([bytes], { type: "image/jpeg" }));
  try {
    const probe = new Image();
    probe.src = url;
    await probe.decode();
    return url;
  } catch {
    URL.revokeObjectURL(url);
    throw new InvalidResponseError();
  }
}

/** CantripDesktopModel: one View Mac lease, its frame loop and encrypted input. */
function useDesktop() {
  const lease = useSignal<DesktopLease | null>(null);
  const frame = useSignal<DesktopFrame | null>(null);
  const image = useSignal<string | null>(null);
  const displayID = useSignal<number | null>(null);
  const busy = useSignal(false);
  const error = useSignal<string | null>(null);
  const key = useRef<CryptoKey | null>(null);
  const sequence = useRef(0);
  const generation = useRef(0);
  const alive = useRef(true);

  const setImage = (url: string | null) => {
    if (image.value) URL.revokeObjectURL(image.value);
    image.value = url;
  };

  const stopLease = (value: DesktopLease) =>
    api<DesktopStopResponse>("/api/v1/desktop/stop", { method: "POST", body: { id: value.id, token: value.token } });

  const stop = async () => {
    generation.current++;
    const old = lease.value;
    key.current = null;
    batch(() => {
      lease.value = null;
      frame.value = null;
      setImage(null);
    });
    if (!old) return;
    try {
      const response = await stopLease(old);
      if (response?.stopped !== true) throw new InvalidResponseError();
    } catch (failure) {
      if (alive.current) error.value = `View cleared. The Mac may keep the lease until its 60-second idle timeout: ${errorText(failure)}`;
    }
  };

  const showing = (active: DesktopLease) => alive.current && lease.value?.id === active.id;

  const poll = async (active: DesktopLease, cryptoKey: CryptoKey) => {
    while (showing(active)) {
      const display = displayID.value;
      if (display === null) return;
      try {
        const next = await api<DesktopFrame>("/api/v1/desktop/frame", {
          method: "POST", body: { id: active.id, token: active.token, displayID: display },
        });
        if (!showing(active)) return;
        if (displayID.value !== display) continue;
        const url = await jpegURL(await decryptDesktopFrame(cryptoKey, active.id, next));
        if (!showing(active) || displayID.value !== display) {
          URL.revokeObjectURL(url);
          continue;
        }
        batch(() => {
          frame.value = next;
          setImage(url);
        });
        await sleep(1000);
      } catch (failure) {
        if (!showing(active)) return;
        error.value = `${errorText(failure)} Viewing stopped; start a new session to reconnect.`;
        await stop();
        return;
      }
    }
  };

  const start = async (control: boolean) => {
    if (busy.value || lease.value) return;
    // Windows stand-in for the Mac's Touch ID / password check: an explicit confirmation per session.
    const confirmed = await confirmDialog({
      title: control ? "Control Mac" : "View Mac",
      message: control ? "Allow viewing and controlling your Mac for five minutes." : "Allow viewing your Mac screen for five minutes.",
      confirm: control ? "Control Mac" : "View Mac",
    });
    if (!confirmed || !alive.current || busy.value || lease.value) return;
    busy.value = true;
    const started = generation.current;
    try {
      if (!globalThis.crypto?.subtle) throw new Error("A secure context is required for encrypted viewing.");
      let value: DesktopLease;
      try {
        value = await remote.mutate(async () => {
          const status = await fetchAccess();
          if (!status.desktopEnabled) throw new Error("Enable View Mac in Cantrip settings on the Mac first.");
          return api<DesktopLease>("/api/v1/desktop/start", { method: "POST", body: { control } });
        });
      } catch (failure) {
        throw new Error(writeFailure(failure) || "View Mac could not start. It may have reached the Mac; check before retrying.");
      }
      if (!alive.current || started !== generation.current) {
        // Closed or stopped while starting: end the lease the Mac just granted.
        void stopLease(value).catch(() => undefined);
        if (alive.current) error.value = "Authentication or connection changed. No viewing session was confirmed.";
        return;
      }
      let cryptoKey: CryptoKey;
      try {
        cryptoKey = await importDesktopKey(value.key);
      } catch (failure) {
        void stopLease(value).catch(() => undefined);
        throw failure;
      }
      if (!alive.current || started !== generation.current) {
        void stopLease(value).catch(() => undefined);
        return;
      }
      key.current = cryptoKey;
      sequence.current = 0;
      batch(() => {
        lease.value = value;
        displayID.value = value.displays[0]?.id ?? null;
        frame.value = null;
        setImage(null);
        error.value = null;
      });
      void poll(value, cryptoKey);
    } catch (failure) {
      if (alive.current) error.value = errorText(failure);
    } finally {
      busy.value = false;
    }
  };

  const send = async (command: Omit<DesktopCommand, "frameID">) => {
    const active = lease.value;
    const shown = frame.value;
    const cryptoKey = key.current;
    if (!active?.control || busy.value || !shown || !cryptoKey) return;
    busy.value = true;
    sequence.current += 1;
    const number = sequence.current;
    try {
      const encrypted = await encryptDesktopCommand(cryptoKey, active.id, number, { ...command, frameID: shown.id });
      const response = await remote.mutate(() => api<AcceptedResponse>("/api/v1/desktop/input", {
        method: "POST", body: { id: active.id, token: active.token, sequence: number, encrypted },
      }));
      if (response?.accepted !== true) throw new InvalidResponseError();
      if (alive.current) error.value = null;
    } catch (failure) {
      if (alive.current) {
        error.value = `${writeFailure(failure) || "Desktop input could not be confirmed."} Input was not retried. Check the screen before trying again.`;
      }
    } finally {
      busy.value = false;
    }
  };

  const chooseDisplay = (id: number) => {
    if (displayID.value === id) return;
    batch(() => {
      displayID.value = id;
      frame.value = null;
      setImage(null);
    });
  };

  useEffect(() => () => {
    void stop();
    alive.current = false;
  }, []);

  return { lease, frame, image, displayID, busy, error, start, stop, send, chooseDisplay };
}

export function MacAccessSheet(props: { onClose: () => void }): JSX.Element | null {
  const snapshot = useSignal<MacAccessSnapshot | null>(null);
  const error = useSignal<string | null>(null);
  const control = useSignal(savedControl());
  const zoom = useSignal(1);
  const clickKind = useSignal<DesktopCommandKind>("click");
  const [text, setText] = useState("");
  const settingsBusy = useSignal(false);
  const desktop = useDesktop();
  const alive = useAlive();
  const ids = { control: useId(), display: useId(), click: useId(), text: useId() };

  const load = async () => {
    try {
      const value = await fetchAccess();
      if (!alive.current) return;
      snapshot.value = value;
      error.value = null;
    } catch (failure) {
      if (alive.current) error.value = errorText(failure);
    }
  };

  useEffect(() => { void load(); }, []);

  // Hiding the window ends viewing (the Mac stops when its scene leaves the foreground).
  useEffect(() => {
    const onVisibility = () => {
      if (document.visibilityState !== "hidden") return;
      setText("");
      void desktop.stop();
    };
    document.addEventListener("visibilitychange", onVisibility);
    return () => document.removeEventListener("visibilitychange", onVisibility);
  }, []);

  const done = () => {
    setText("");
    void desktop.stop();
    props.onClose();
  };

  const openSettings = async (permission: MacPermission) => {
    settingsBusy.value = true;
    try {
      const response = await remote.mutate(async () => {
        await fetchAccess();
        return api<OpenMacSettingsResponse>("/api/v1/mac-access", { method: "POST", body: { permission } });
      });
      if (response?.opened !== true) throw new InvalidResponseError();
      if (alive.current) error.value = null;
    } catch (failure) {
      if (alive.current) error.value = writeFailure(failure) || "Settings could not be opened.";
    } finally {
      settingsBusy.value = false;
    }
  };

  const lease = desktop.lease.value;
  const shown = desktop.frame.value;
  const image = desktop.image.value;
  const busy = desktop.busy.value;
  const value = snapshot.value;
  const message = desktop.error.value ?? error.value;
  const textTooLong = utf8Length(text) > DESKTOP_TEXT_LIMIT;

  const sendText = () => {
    if (!shown || text === "" || textTooLong) return;
    const typed = text;
    setText("");
    void desktop.send({ kind: "text", text: typed });
  };

  return (
    <Sheet title="Mac Access" onClose={done} width={760} height={620}
      actions={<button type="button" class="btn" onClick={() => void load()}>Refresh</button>}
      footer={<button type="button" class="btn primary" onClick={done}>Done</button>}>
      <div class="sh-access">
        <div class="sh-stack">
          <span class="headline">{value?.name ?? "Cantrip Mac"}</span>
          <p class="sh-footnote muted">Explicit remote viewing only. Screen frames and typed input are not saved or sent to the model. The paired connection carries the viewing key; only use a trusted HTTPS endpoint.</p>
          <p class="sh-footnote muted">A confirmation on this PC starts each View Mac session. It authorizes Cantrip Gateway actions, not macOS Touch ID or Keychain access.</p>
        </div>
        <div role="alert">{message ? <p class="sh-warning selectable">{message}</p> : null}</div>
        {lease ? (
          <>
            <div class="sh-stack">
              <StatusLabel icon="desktopcomputer">View Mac active - expires in five minutes</StatusLabel>
              <Caption>Five-minute maximum; disconnects expire after 60 seconds. Frames refresh about once per second.</Caption>
            </div>
            <div class="sh-buttons">
              <label for={ids.display}>Display</label>
              <select id={ids.display} class="select" value={String(desktop.displayID.value ?? "")}
                onChange={(event) => { setText(""); desktop.chooseDisplay(Number(event.currentTarget.value)); }}>
                {lease.displays.map((display) => (
                  <option key={display.id} value={String(display.id)} selected={display.id === desktop.displayID.value}>{display.name}</option>
                ))}
              </select>
              <span class="grow" />
              <span id={`${ids.display}-zoom`}>Zoom</span>
              <div class="segmented" role="group" aria-labelledby={`${ids.display}-zoom`}>
                {[1, 2, 3].map((level) => (
                  <button key={level} type="button" aria-pressed={zoom.value === level ? "true" : "false"}
                    onClick={() => { zoom.value = level; }}>{level}x</button>
                ))}
              </div>
            </div>
            {image && shown ? (
              <div class={`sh-viewport${zoom.value > 1 ? " zoomed" : ""}`} aria-busy={busy ? "true" : "false"}>
                <img src={image} alt="Live Mac screen. Use zoom and click to control when enabled. Press Enter to click the center of the display."
                  class={lease.control ? undefined : "view-only"} style={{ width: `${zoom.value * 100}%` }} tabIndex={0} draggable={false}
                  onClick={(event) => {
                    if (!lease.control || busy) return;
                    const point = normalizedPoint(event.clientX, event.clientY, event.currentTarget.getBoundingClientRect());
                    if (point) void desktop.send({ kind: clickKind.value, x: point.x, y: point.y });
                  }}
                  onKeyDown={(event) => {
                    if (!lease.control || (event.key !== "Enter" && event.key !== " ")) return;
                    event.preventDefault();
                    void desktop.send({ kind: "click", x: 0.5, y: 0.5 });
                  }}
                  onContextMenu={(event) => event.preventDefault()} />
              </div>
            ) : (
              <div class="sh-viewport waiting"><Loading text="Waiting for a screen frame..." /></div>
            )}
            {lease.control ? (
              <fieldset class="sh-fieldset" disabled={busy || !shown}>
                <form class="sh-controls" onSubmit={(event) => { event.preventDefault(); sendText(); }}>
                  <div class="sh-buttons">
                    <label for={ids.click}>Click action</label>
                    <select id={ids.click} class="select" value={clickKind.value}
                      onChange={(event) => { clickKind.value = event.currentTarget.value as DesktopCommandKind; }}>
                      <option value="click" selected={clickKind.value === "click"}>Click</option>
                      <option value="rightClick" selected={clickKind.value === "rightClick"}>Right click</option>
                      <option value="doubleClick" selected={clickKind.value === "doubleClick"}>Double click</option>
                    </select>
                  </div>
                  <input id={ids.text} class="text-field" type="password" value={text} maxLength={DESKTOP_TEXT_LIMIT}
                    placeholder="Type into the focused Mac field" aria-label="Type into the focused Mac field"
                    autocomplete="off" spellcheck={false} onInput={(event) => setText(event.currentTarget.value)} />
                  <Caption>Click the target field first. Confirm its focus before sending a password; the Mac may display typed text.</Caption>
                  <div><button type="submit" class="btn" disabled={text === "" || textTooLong}>Send Text</button></div>
                  <div class="sh-keys" role="group" aria-label="Keys">
                    {DESKTOP_KEY_BUTTONS.map((name) => (
                      <button key={name} type="button" class="btn" onClick={() => void desktop.send({ kind: "key", key: name })}>
                        {capitalized(name)}
                      </button>
                    ))}
                  </div>
                  <div class="sh-buttons">
                    <button type="button" class="btn" onClick={() => void desktop.send({ kind: "scroll", delta: 3 })}>Scroll up</button>
                    <button type="button" class="btn" onClick={() => void desktop.send({ kind: "scroll", delta: -3 })}>Scroll down</button>
                  </div>
                </form>
              </fieldset>
            ) : null}
            <p class="sh-footnote">Protected dialogs may be hidden or reject input. A sent click is not confirmation that macOS authorized an operation. Touch ID cannot be performed remotely.</p>
            <div>
              <button type="button" class="btn large destructive" onClick={() => { setText(""); void desktop.stop().then(load); }}>
                End View Mac
              </button>
            </div>
          </>
        ) : (
          <>
            <div class="row">
              <label for={ids.control} class="grow">Enable keyboard and pointer control</label>
              <input id={ids.control} type="checkbox" role="switch" class="switch" checked={control.value} disabled={busy}
                onChange={(event) => {
                  control.value = event.currentTarget.checked;
                  try { localStorage.setItem(CONTROL_KEY, String(control.value)); } catch { /* storage unavailable */ }
                }} />
            </div>
            <Caption>Your control preference is saved. Confirm to start each session; Done ends the session.</Caption>
            <button type="button" class="btn primary large sh-start" disabled={value?.desktopEnabled !== true || busy}
              onClick={() => void desktop.start(control.value)}>
              <Icon name="lock.shield.fill" />
              <span>{control.value ? "Confirm & Control Mac" : "Confirm & View Mac"}</span>
            </button>
            {value?.desktopEnabled !== true ? (
              <p class="sh-footnote">
                First enable “Allow paired clients to view and control this Mac” in Cantrip settings on the Mac. This PC cannot enable this permission remotely.
              </p>
            ) : null}
          </>
        )}
        <fieldset class="sh-fieldset" disabled={settingsBusy.value}>
          <div class="sh-stack wide">
            <h3 class="sh-section-title">Mac Permissions &amp; Attention</h3>
            {(value?.issues ?? []).map((issue) => <span key={issue.id} class="sh-warning">{issue.title}</span>)}
            {(value?.permissions ?? []).map((permission) => (
              <div key={permission.permission} class="sh-permission">
                <span>{permission.title}: {permissionStateLabel(permission.state)}</span>
                <button type="button" class="btn" onClick={() => void openSettings(permission.permission)}>
                  Open {permission.title} on Mac
                </button>
              </div>
            ))}
            <p class="sh-footnote muted">Full Disk Access needs a manual check. Keychain status covers Cantrip's own credential reads, not every application's dialog. These buttons open settings; they never grant permissions.</p>
          </div>
        </fieldset>
      </div>
    </Sheet>
  );
}
