import { afterEach, expect, it, vi } from "vitest";
import type { HostStatus } from "../src/gateway/bridge";
import { deferred, revisionA, settle, syntheticPack } from "./private-mascot-fixture";

afterEach(() => vi.unstubAllGlobals());

it("uses the existing authenticated bridge with no cache and fences equally named paired Macs", async () => {
  let statusChanged!: (status: HostStatus) => void;
  const status = { connected: true, route: "Direct, encrypted", message: "", server: "Mac", connectionID: "pair-one" };
  const handlers = new Map<string, () => void>();
  vi.stubGlobal("window", {
    cantripGateway: { key: "fixture-window-key", status, onStatus: (listener: typeof statusChanged) => { statusChanged = listener; } },
    addEventListener: (event: string, callback: () => void) => handlers.set(event, callback),
  });
  vi.stubGlobal("localStorage", { getItem: () => null });
  const pending = deferred<Response>(), close = vi.fn();
  const fetch = vi.fn().mockReturnValueOnce(pending.promise).mockResolvedValueOnce(new Response(JSON.stringify(syntheticPack())));
  vi.stubGlobal("fetch", fetch);
  vi.stubGlobal("createImageBitmap", vi.fn().mockResolvedValue({ width: 1, height: 1, close }));
  const { privateMascotLoader: loader, personalMascot } = await import("../src/gateway/state/privateMascot");
  loader.observe(revisionA);
  expect(fetch).toHaveBeenCalledOnce();
  expect(fetch.mock.calls[0][0]).toBe(`/api/v1/mascot?revision=${revisionA}&history=recent`);
  expect(fetch.mock.calls[0][1]).toMatchObject({
    method: "GET", cache: "no-store", headers: { accept: "application/json", "x-cantrip-gateway": "fixture-window-key" },
  });
  statusChanged({ ...status, connectionID: "pair-two" });
  expect(fetch.mock.calls[0][1].signal.aborted).toBe(true);
  expect(personalMascot.value.pack).toBeNull();
  loader.observe(revisionA);
  pending.resolve(new Response(JSON.stringify(syntheticPack())));
  // Response.text() also schedules stream tasks, unlike the model's already-parsed request fixtures.
  await vi.waitFor(() => expect(personalMascot.value.pack).not.toBeNull());
  expect(fetch).toHaveBeenCalledTimes(2);
  handlers.get("pagehide")!(); await settle();
  expect(personalMascot.value.pack).toBeNull();
  expect(close).toHaveBeenCalledTimes(2);
});
