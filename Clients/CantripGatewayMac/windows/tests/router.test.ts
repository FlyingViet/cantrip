import { describe, expect, it } from "vitest";
import { HostRouter, Route, routesFor } from "../src/main/router";
import { HostRequest, HostResponse, TransportError } from "../src/main/transport";

const direct: Route = { kind: "direct", address: "192.168.0.20:8766", host: "192.168.0.20", port: 8766 };
const https: Route = { kind: "https", origin: "https://mac.example.ts.net/" };
const ok: HostResponse = { status: 200, headers: {}, body: Buffer.from("{}") };
const get: HostRequest = { method: "GET", path: "/api/v1/sessions", headers: {} };
const post: HostRequest = { method: "POST", path: "/api/v1/sessions/x/messages", headers: {} };

function harness(failures: Partial<Record<Route["kind"], TransportError | null>>) {
  const calls: string[] = [];
  const changes: string[] = [];
  let clock = 0;
  const router = new HostRouter([direct, https], async (route, request) => {
    calls.push(`${route.kind} ${request.method}`);
    const failure = failures[route.kind];
    if (failure) throw failure;
    return ok;
  }, (route) => changes.push(route.kind), () => clock, 60000);
  return { router, calls, changes, advance: (ms: number) => { clock += ms; } };
}

describe("routesFor", () => {
  it("puts the encrypted direct route first and skips it for Tailscale only", () => {
    expect(routesFor({ name: "", url: https.origin, directAddress: "192.168.0.20:8766", tailscaleOnly: false }).map((r) => r.kind))
      .toEqual(["direct", "https"]);
    expect(routesFor({ name: "", url: https.origin, directAddress: "192.168.0.20:8766", tailscaleOnly: true }).map((r) => r.kind))
      .toEqual(["https"]);
    expect(routesFor({ name: "", url: "", directAddress: "[fd7a::1]:8766", tailscaleOnly: false })[0])
      .toMatchObject({ host: "fd7a::1", port: 8766 });
  });
});

describe("HostRouter", () => {
  it("falls back for reads and sticks with the route that worked", async () => {
    const test = harness({ direct: new TransportError("down", false, "connect") });
    await test.router.request(get);
    await test.router.request(get);
    expect(test.calls).toEqual(["direct GET", "https GET", "https GET"]);
    expect(test.changes).toEqual(["https"]);
  });

  it("retries a mutation only when it never left this computer", async () => {
    const notSent = harness({ direct: new TransportError("refused", false, "connect") });
    await notSent.router.request(post);
    expect(notSent.calls).toEqual(["direct POST", "https POST"]);

    const maybeSent = harness({ direct: new TransportError("reset", true, "protocol") });
    await expect(maybeSent.router.request(post)).rejects.toThrow("reset");
    expect(maybeSent.calls).toEqual(["direct POST"]);
  });

  it("still retries reads that may have been sent", async () => {
    const test = harness({ direct: new TransportError("reset", true, "protocol") });
    await test.router.request(get);
    expect(test.calls).toEqual(["direct GET", "https GET"]);
  });

  it("tries the better route again once a minute while on a fallback", async () => {
    const failures: Partial<Record<Route["kind"], TransportError | null>> = { direct: new TransportError("down", false, "connect") };
    const test = harness(failures);
    await test.router.request(get);
    test.advance(30000);
    await test.router.request(get);
    expect(test.calls).toEqual(["direct GET", "https GET", "https GET"]);
    failures.direct = null;
    test.advance(30000);
    await test.router.request(post); // mutations never probe
    await test.router.request(get);
    expect(test.calls.slice(3)).toEqual(["https POST", "direct GET"]);
    expect(test.router.current.kind).toBe("direct");
    expect(test.changes).toEqual(["https", "direct"]);
  });

  it("reports the last failure when every route is down", async () => {
    const test = harness({ direct: new TransportError("lan down", false, "connect"), https: new TransportError("tailscale down", false, "connect") });
    await expect(test.router.request(get)).rejects.toThrow("tailscale down");
  });
});
