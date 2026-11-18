// Read-only Cantrip Home for this PC: every request is a GET the service builds itself from a
// checked `HomeRead`, sent over the paired Mac's encrypted routes with the pairing token, which
// never leaves the main process. The only writes are a view's Refresh and the view's own `refresh`
// and `open` buttons, and only buttons the Mac sent for that view in its last answer. Upcoming is
// read-only here: its cancel and resume posts stay on the phone and the Mac.
import { UUID_PATTERN } from "../../shared/home";
import type { HomePairResult, HomeRead, HomeReadResult, HomeStatus, HomeViewWrite } from "../../shared/home";
import { HOME_WINDOW_ACTION_KINDS, VIEW_ID_PATTERN, viewActionIDs } from "../../shared/views";
import { PairingError, displayName, parsePairingLink } from "./pairing";
import { HostRouter, describeRoute, routesFor } from "./router";
import type { Route } from "./router";
import type { Pairing, PairingStore } from "./store";
import { TransportError } from "./transport";
import type { HostRequest, HostResponse } from "./transport";

export type SendWithToken = (route: Route, token: string, request: HostRequest) => Promise<HostResponse>;

const REVISION = /^[A-Za-z0-9._:+=\/-]{1,128}$/;
const UNAUTHORIZED = "The Mac rejected this PC's pairing. Run cantrip pair on the Mac and pair again.";

/** The Mac path for `read`, or an Error for anything this window may not ask for. */
export function homeReadPath(read: unknown, logSessionID: string | null): string {
  if (!read || typeof read !== "object") throw new Error("Invalid Home request.");
  const request = read as Record<string, unknown>;
  switch (request.kind) {
    case "home":
      return "/api/v1/home?history=recent&recentExchanges=3";
    case "background":
      return "/api/v1/home/background";
    case "log":
      if (!logSessionID) throw new Error("Open Background first.");
      return `/api/v1/sessions/${logSessionID}?history=recent&recentExchanges=3`;
    case "tasks": {
      if (request.revision === undefined) return "/api/v1/home/tasks";
      if (typeof request.revision !== "string" || !REVISION.test(request.revision)) throw new Error("Invalid Home request.");
      return `/api/v1/home/tasks?revision=${encodeURIComponent(request.revision)}`;
    }
    case "recordCards": {
      const { taskID, recordID } = request;
      if (typeof taskID !== "string" || typeof recordID !== "string" || !UUID_PATTERN.test(taskID) || !UUID_PATTERN.test(recordID)) {
        throw new Error("Invalid Home request.");
      }
      return `/api/v1/home/tasks/${taskID}/records/${recordID}/cards`;
    }
    case "views": {
      if (request.revision === undefined) return "/api/v1/home/views";
      if (typeof request.revision !== "string" || !REVISION.test(request.revision)) throw new Error("Invalid Home request.");
      return `/api/v1/home/views?revision=${encodeURIComponent(request.revision)}`;
    }
    case "view":
      return viewPath(request.viewID);
    case "upcoming": {
      if (request.revision === undefined) return "/api/v1/home/upcoming";
      if (typeof request.revision !== "string" || !REVISION.test(request.revision)) throw new Error("Invalid Home request.");
      return `/api/v1/home/upcoming?revision=${encodeURIComponent(request.revision)}`;
    }
    default:
      throw new Error("Invalid Home request.");
  }
}

function viewPath(viewID: unknown): string {
  if (typeof viewID !== "string" || !VIEW_ID_PATTERN.test(viewID)) throw new Error("Invalid Home request.");
  return `/api/v1/home/views/${encodeURIComponent(viewID)}`;
}

/**
 * The Mac path and body for `write`, or an Error for anything this window may not do. An action must be one of
 * the `refresh` or `open` buttons the Mac last sent for that view (`allowed`); its body always says the user
 * confirmed it, as the Mac requires.
 */
export function homeWriteRequest(write: unknown, allowed: (viewID: string) => ReadonlySet<string> | undefined): { path: string; body?: unknown } {
  if (!write || typeof write !== "object") throw new Error("Invalid Home request.");
  const request = write as Record<string, unknown>;
  const view = viewPath(request.viewID);
  switch (request.kind) {
    case "refresh":
      return { path: `${view}/refresh` };
    case "action": {
      const { actionID } = request;
      if (typeof actionID !== "string" || !VIEW_ID_PATTERN.test(actionID) || !allowed(request.viewID as string)?.has(actionID)) {
        throw new Error("This window can't run that button.");
      }
      return { path: `${view}/actions/${encodeURIComponent(actionID)}`, body: { confirmed: true } };
    }
    default:
      throw new Error("Invalid Home request.");
  }
}

/** The Mac's `{"error": "…"}` message, or a generic one for the status. */
export function errorMessage(response: HostResponse): string {
  if (response.status === 401) return UNAUTHORIZED;
  try {
    const parsed = JSON.parse(response.body.toString("utf8")) as { error?: unknown };
    if (typeof parsed?.error === "string" && parsed.error.trim()) return parsed.error.trim().slice(0, 300);
  } catch { /* not JSON */ }
  return `The Mac answered with HTTP ${response.status}.`;
}

export class HomeService {
  private pairing: Pairing | null;
  private router: HostRouter | null = null;
  private logSessionID: string | null = null;
  /** Per view: the button IDs this window may post (its `refresh` and `open` buttons, from the Mac's last answer). */
  private viewActions = new Map<string, ReadonlySet<string>>();

  constructor(
    private readonly store: PairingStore,
    private readonly send: SendWithToken,
    private readonly log: (line: string) => void = () => {},
  ) {
    this.pairing = store.load();
    this.router = this.pairing ? this.routerFor(this.pairing) : null;
  }

  private routerFor(pairing: Pairing): HostRouter {
    return new HostRouter(
      routesFor(pairing.server),
      (route, request) => this.send(route, pairing.token, request),
      (route) => this.log(`home: using ${describeRoute(route)}`),
    );
  }

  status(): HomeStatus {
    return {
      paired: Boolean(this.pairing),
      server: this.pairing ? displayName(this.pairing.server) : "",
      route: this.router ? describeRoute(this.router.current) : "",
    };
  }

  /** Checks the link against the Mac, then saves it encrypted. Home being off still pairs. */
  async pair(link: unknown): Promise<HomePairResult> {
    let parsed: ReturnType<typeof parsePairingLink>;
    try {
      parsed = parsePairingLink(typeof link === "string" ? link.slice(0, 4096) : "");
    } catch (error) {
      return { ok: false, error: error instanceof PairingError ? error.message : "This isn't a pairing link." };
    }
    const { token, ...server } = parsed;
    const candidate: Pairing = { server, token };
    const router = this.routerFor(candidate);
    let response: HostResponse;
    try {
      response = await router.request(this.request("/api/v1/home/background", token));
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
    if (response.status !== 200 && response.status !== 409) return { ok: false, error: errorMessage(response) };
    try {
      this.pairing = this.store.save(server, token);
    } catch (error) {
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }
    this.router = router;
    this.logSessionID = null;
    this.viewActions.clear();
    this.log(`home: paired; routes ${routesFor(server).map(describeRoute).join(", ")}`);
    return response.status === 409
      ? { ok: true, status: this.status(), notice: errorMessage(response) }
      : { ok: true, status: this.status() };
  }

  unpair(): HomeStatus {
    this.store.clear();
    this.pairing = null;
    this.router = null;
    this.logSessionID = null;
    this.viewActions.clear();
    this.log("home: unpaired");
    return this.status();
  }

  async read(read: unknown): Promise<HomeReadResult> {
    if (!this.pairing || !this.router) return { ok: false, error: "Pair this PC with your Mac first." };
    let path: string;
    try {
      path = homeReadPath(read, this.logSessionID);
    } catch (error) {
      return { ok: false, error: (error as Error).message };
    }
    let response: HostResponse;
    try {
      response = await this.router.request(this.request(path, this.pairing.token));
    } catch (error) {
      const message = error instanceof TransportError || error instanceof Error ? error.message : String(error);
      this.log(`home: ${(read as HomeRead).kind} failed: ${error instanceof TransportError ? error.kind : "error"}`);
      return { ok: false, error: message };
    }
    if (response.status !== 200) return { ok: false, status: response.status, error: errorMessage(response) };
    let data: unknown;
    try {
      data = JSON.parse(response.body.toString("utf8"));
    } catch {
      return { ok: false, status: response.status, error: "The Mac sent an answer this PC can't read." };
    }
    if ((read as HomeRead).kind === "background") {
      const sessionID = (data as { sessionID?: unknown })?.sessionID;
      this.logSessionID = typeof sessionID === "string" && UUID_PATTERN.test(sessionID) ? sessionID : null;
    }
    if ((read as HomeRead).kind === "view") this.rememberActions((read as { viewID: string }).viewID, data);
    return { ok: true, data };
  }

  /** A view's Refresh, or one of its confirmed `refresh`/`open` buttons; sent once (never repeated on another route once it may have reached the Mac). */
  async viewWrite(write: unknown): Promise<HomeReadResult> {
    if (!this.pairing || !this.router) return { ok: false, error: "Pair this PC with your Mac first." };
    let built: { path: string; body?: unknown };
    try {
      built = homeWriteRequest(write, (viewID) => this.viewActions.get(viewID));
    } catch (error) {
      return { ok: false, error: (error as Error).message };
    }
    const { viewID, kind } = write as HomeViewWrite;
    const token = this.pairing.token;
    const request: HostRequest = {
      method: "POST",
      path: built.path,
      headers: { authorization: `Bearer ${token}`, accept: "application/json", "content-type": "application/json" },
      body: Buffer.from(built.body === undefined ? "" : JSON.stringify(built.body)),
    };
    let response: HostResponse;
    try {
      response = await this.router.perform(kind === "refresh", (route) => this.send(route, token, request));
    } catch (error) {
      const message = error instanceof TransportError || error instanceof Error ? error.message : String(error);
      this.log(`home: view ${kind} failed: ${error instanceof TransportError ? error.kind : "error"}`);
      return { ok: false, error: message };
    }
    if (response.status !== 200) return { ok: false, status: response.status, error: errorMessage(response) };
    let data: unknown;
    try {
      data = JSON.parse(response.body.toString("utf8"));
    } catch {
      return { ok: false, status: response.status, error: "The Mac sent an answer this PC can't read." };
    }
    if (kind === "refresh" || (data as { result?: unknown })?.result === "refreshed") this.rememberActions(viewID, data);
    return { ok: true, data };
  }

  private rememberActions(viewID: string, data: unknown): void {
    const card = (data as { card?: unknown } | null)?.card;
    if (card === undefined) return;
    this.viewActions.set(viewID, new Set(viewActionIDs(card, HOME_WINDOW_ACTION_KINDS)));
    while (this.viewActions.size > 32) this.viewActions.delete(this.viewActions.keys().next().value!);
  }

  private request(path: string, token: string): HostRequest {
    return { method: "GET", path, headers: { authorization: `Bearer ${token}`, accept: "application/json" } };
  }
}
