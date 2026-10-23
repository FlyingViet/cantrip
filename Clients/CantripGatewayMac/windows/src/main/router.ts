import { ServerConfig, splitDirectAddress } from "./pairing";
import { HostRequest, HostResponse, TransportError } from "./transport";

export type Route =
  | { kind: "direct"; address: string; host: string; port: number }
  | { kind: "https"; origin: string };

/** The encrypted direct (TLS-PSK) route first: it works without Tailscale on the home network. */
export function routesFor(server: ServerConfig): Route[] {
  const routes: Route[] = [];
  if (server.directAddress && !server.tailscaleOnly) {
    routes.push({ kind: "direct", address: server.directAddress, ...splitDirectAddress(server.directAddress) });
  }
  if (server.url) routes.push({ kind: "https", origin: server.url });
  return routes;
}

export function describeRoute(route: Route): string {
  return route.kind === "direct" ? `Direct, encrypted (${route.address})` : `HTTPS (${new URL(route.origin).host})`;
}

export type Send = (route: Route, request: HostRequest) => Promise<HostResponse>;

/**
 * Sends each request over the preferred route and falls back in priority order. Reads may be
 * retried on another route; a mutation is retried only when it never left this computer, so an
 * uncertain send is never replayed. While a fallback is in use, a read retries the better routes
 * at most once per `promoteAfterMs`.
 */
export class HostRouter {
  private preferred = 0;
  private lastPromotionAttempt = 0;

  constructor(
    private readonly routes: Route[],
    private readonly send: Send,
    private readonly onRouteChange: (route: Route) => void = () => {},
    private readonly now: () => number = Date.now,
    private readonly promoteAfterMs = 60000,
  ) {
    if (!routes.length) throw new Error("No routes to the Mac are configured.");
  }

  get current(): Route {
    return this.routes[this.preferred];
  }

  async request(request: HostRequest): Promise<HostResponse> {
    const idempotent = request.method === "GET" || request.method === "HEAD";
    const order = this.routes.map((_, index) => index);
    const promote = idempotent && this.preferred > 0 && this.now() - this.lastPromotionAttempt >= this.promoteAfterMs;
    if (promote) this.lastPromotionAttempt = this.now();
    else order.sort((a, b) => (a === this.preferred ? -1 : b === this.preferred ? 1 : a - b));

    let lastError: unknown;
    for (const index of order) {
      try {
        const response = await this.send(this.routes[index], request);
        if (index !== this.preferred) {
          this.preferred = index;
          this.onRouteChange(this.routes[index]);
        }
        return response;
      } catch (error) {
        lastError = error;
        if (!(error instanceof TransportError)) throw error;
        if (error.requestSent && !idempotent) throw error;
      }
    }
    throw lastError;
  }
}
