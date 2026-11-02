import { describe, expect, it } from "vitest";
import { keepNewToken, settingsBridgeRequest, settingsRevisionInfo, takePairingToken, type KeepNewTokenDeps } from "../src/main/settingsBridge";

describe("Settings' requests for the Mac's settings", () => {
  it("passes the manifest, changes, buttons, keep and revert", () => {
    expect(settingsBridgeRequest({ method: "GET" })).toEqual({ method: "GET" });
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "abc", changes: { remoteLANPort: 0, allowActions: true, claudeEffort: "" } } }))
      .toEqual({ method: "POST", body: '{"revision":"abc","changes":{"remoteLANPort":0,"allowActions":true,"claudeEffort":""}}' });
    expect(settingsBridgeRequest({ method: "POST", body: { action: "rotatePairingToken" } }))
      .toEqual({ method: "POST", body: '{"action":"rotatePairingToken"}' });
    expect(settingsBridgeRequest({ method: "POST", body: { keep: "6F1C2B0E-2E55-4C59-9A7B-8E0D5C1F0A11" } })).toHaveProperty("method", "POST");
    expect(settingsBridgeRequest({ method: "POST", body: { revert: "6F1C2B0E-2E55-4C59-9A7B-8E0D5C1F0A11" } })).toHaveProperty("method", "POST");
  });

  it("refuses anything else", () => {
    expect(settingsBridgeRequest(null)).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "DELETE" })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "GET", body: {} })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: [] })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { action: "x", keep: "y" } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { changes: { a: 1 } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: {} } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: { "../path": 1 } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: { a: { nested: true } } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: { a: null } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: { a: Number.NaN } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { revision: "r", changes: { a: "x".repeat(70_000) } } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { action: "" } })).toHaveProperty("error");
    expect(settingsBridgeRequest({ method: "POST", body: { keep: 7 } })).toHaveProperty("error");
  });

  it("forwards the polled revision only when it's well formed", () => {
    expect(settingsRevisionInfo({ supportsSettings: true, settingsRevision: "0a1b" })).toEqual({ supportsSettings: true, settingsRevision: "0a1b" });
    expect(settingsRevisionInfo({ supportsSettings: false, settingsRevision: "" })).toEqual({ supportsSettings: false, settingsRevision: "" });
    expect(settingsRevisionInfo({ supportsSettings: "yes", settingsRevision: "0a1b" })).toBeNull();
    expect(settingsRevisionInfo({ supportsSettings: true })).toBeNull();
    expect(settingsRevisionInfo(null)).toBeNull();
  });
});

describe("a replaced pairing token", () => {
  const token = "N".repeat(43);

  it("never goes to the window", () => {
    const reply = { revision: "r", pages: [], result: { message: "Replaced. Other devices have to pair again.", pairingToken: token } };
    const taken = takePairingToken(reply);
    expect(taken.token).toBe(token);
    expect(JSON.stringify(taken.body)).not.toContain(token);
    expect(taken.body).toEqual({ revision: "r", pages: [], result: { message: "Replaced. Other devices have to pair again." } });
    expect(takePairingToken({ result: { pairingToken: 5 } })).toEqual({ body: { result: {} }, token: null });
    const plain = { revision: "r", result: { message: "Removed." } };
    expect(takePairingToken(plain)).toEqual({ body: plain, token: null });
    expect(takePairingToken(null)).toEqual({ body: null, token: null });
  });

  /** A Mac that answers each request in turn; the clock moves with each wait. */
  function mac(replies: Array<{ status: number; body?: unknown } | Error>): KeepNewTokenDeps & { sent: string[] } {
    let now = 0;
    const sent: string[] = [];
    return {
      sent,
      now: () => now,
      sleep: async (milliseconds) => { now += milliseconds; },
      send: async (request) => {
        sent.push(request.method === "GET" ? "GET" : request.body!);
        const reply = replies.shift() ?? new Error("ECONNREFUSED");
        if (reply instanceof Error) throw reply;
        return { status: reply.status, body: reply.body ?? null };
      },
    };
  }
  const keep = '{"keep":"P1"}';

  it("keeps it once the Mac has switched to it", async () => {
    const deps = mac([{ status: 401 }, new Error("ECONNREFUSED"), { status: 200, body: { revision: "after" } }]);
    expect(await keepNewToken("P1", deps)).toEqual({ kept: true, manifest: { revision: "after" } });
    expect(deps.sent).toEqual([keep, keep, keep]);
  });

  it("treats a 409 as kept when the new token works and nothing waits", async () => {
    const deps = mac([{ status: 409 }, { status: 200, body: { revision: "after" } }]);
    expect(await keepNewToken("P1", deps)).toEqual({ kept: true, manifest: { revision: "after" } });
    expect(deps.sent).toEqual([keep, "GET"]);
  });

  it("knows the Mac undid it when the new token is refused after a 409", async () => {
    expect(await keepNewToken("P1", mac([{ status: 409 }, { status: 401 }]))).toEqual({ kept: false, reason: "undone" });
  });

  it("gives up after about ten seconds", async () => {
    const deps = mac([]);
    expect(await keepNewToken("P1", deps)).toEqual({ kept: false, reason: "unreachable" });
    expect(deps.sent.length).toBe(14);
  });
});
