/**
 * Pairing data, validated the way Cantrip Agent / Gateway Mac validate it.
 * Link: cantripagent://pair?v=1&name=<label>&token=<token>[&url=<https>][&direct=<host:port>][&tailscaleOnly=1]
 */

export interface ServerConfig {
  /** Display only. */
  name: string;
  /** Normalized HTTPS origin with a trailing slash (Tailscale Serve), or "". */
  url: string;
  /** host:port of the Mac's encrypted TLS-PSK listener, or "". */
  directAddress: string;
  /** Skip the direct (TLS-PSK) route and use only the HTTPS URL. */
  tailscaleOnly: boolean;
}

export interface PairingLink extends ServerConfig {
  token: string;
}

export class PairingError extends Error {}

const LINK_FIELDS = new Set(["v", "name", "token", "url", "direct", "tailscaleOnly"]);
const RETRY = "Run cantrip pair on the Mac again.";
export const DIRECT_EXAMPLE = "192.168.0.20:8766";

export function validateToken(raw: string): string {
  const token = raw.trim();
  if (token.length < 32 || token.length > 128 || !/^[A-Za-z0-9_-]+$/.test(token)) {
    throw new PairingError("The pairing token must be 32 to 128 letters, numbers, dashes or underscores. Copy it from Cantrip's Remote control settings on the Mac.");
  }
  return token;
}

/** "" stays "". HTTPS anywhere; plain HTTP only for this computer (testing). */
export function normalizeURL(raw: string): string {
  const trimmed = raw.trim();
  if (!trimmed) return "";
  let url: URL;
  try {
    url = new URL(trimmed.includes("://") ? trimmed : `https://${trimmed}`);
  } catch {
    throw new PairingError("The URL isn't valid. Use the Mac's https:// address, for example its Tailscale name.");
  }
  const loopback = ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname);
  if (url.protocol !== "https:" && !(url.protocol === "http:" && loopback)) {
    throw new PairingError("The URL must start with https://.");
  }
  if (url.username || url.password || url.search || url.hash) {
    throw new PairingError("The URL can't include a user name, query or fragment.");
  }
  if (!url.pathname.endsWith("/")) url.pathname += "/";
  return url.toString();
}

/** "" stays "". Returns host:port; IPv6 hosts keep their brackets. */
export function normalizeDirectAddress(raw: string | undefined): string {
  const trimmed = (raw ?? "").trim();
  if (!trimmed) return "";
  const match = /^(\[[0-9A-Fa-f:.]+\]|[A-Za-z0-9.-]+):(\d{1,5})$/.exec(trimmed);
  const port = match ? Number(match[2]) : 0;
  if (!match || port < 1 || port > 65535 || match[1].startsWith("-") || match[1].endsWith("-")) {
    throw new PairingError(`The direct address must be host:port, for example ${DIRECT_EXAMPLE}.`);
  }
  return `${match[1].toLowerCase()}:${port}`;
}

export function splitDirectAddress(address: string): { host: string; port: number } {
  const index = address.lastIndexOf(":");
  const host = address.slice(0, index).replace(/^\[(.*)\]$/, "$1");
  return { host, port: Number(address.slice(index + 1)) };
}

/** One line, at most 80 characters, without control or bidi-format characters. */
export function cleanName(raw: string | undefined): string {
  const words = (raw ?? "").replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, " ").split(/\s+/).filter(Boolean);
  return words.join(" ").slice(0, 80).trim();
}

export function validateServer(input: ServerConfig): ServerConfig {
  const url = normalizeURL(input.url);
  const directAddress = normalizeDirectAddress(input.directAddress);
  if (input.tailscaleOnly && !url) throw new PairingError("Tailscale only needs the Mac's https:// URL.");
  if (!url && !directAddress) {
    throw new PairingError(`Add the Mac's direct address (for example ${DIRECT_EXAMPLE}) or its https:// URL.`);
  }
  return { name: cleanName(input.name), url, directAddress, tailscaleOnly: Boolean(input.tailscaleOnly) };
}

export function parsePairingLink(raw: string): PairingLink {
  let link: URL;
  try {
    link = new URL(raw.trim());
  } catch {
    throw new PairingError(`This isn't a pairing link. ${RETRY}`);
  }
  if (link.protocol !== "cantripagent:" || link.hostname.toLowerCase() !== "pair") {
    throw new PairingError(`This isn't a Cantrip pairing link. ${RETRY}`);
  }
  if ((link.pathname && link.pathname !== "/") || link.hash) {
    throw new PairingError(`This pairing link is incomplete or damaged. ${RETRY}`);
  }
  const query = new Map<string, string>();
  for (const [key, value] of link.searchParams) {
    if (!LINK_FIELDS.has(key)) continue;
    if (query.has(key)) throw new PairingError(`This pairing link is incomplete or damaged. ${RETRY}`);
    query.set(key, value);
  }
  const version = Number(query.get("v"));
  if (!Number.isInteger(version) || version < 1) throw new PairingError(`This pairing link is incomplete or damaged. ${RETRY}`);
  if (version !== 1) throw new PairingError("Update Cantrip Gateway to pair with this Mac.");
  const tailscale = query.get("tailscaleOnly");
  if (tailscale !== undefined && tailscale !== "0" && tailscale !== "1") {
    throw new PairingError(`This pairing link is incomplete or damaged. ${RETRY}`);
  }
  let token: string;
  try {
    token = validateToken(query.get("token") ?? "");
  } catch {
    throw new PairingError(`This pairing link's token is invalid. ${RETRY}`);
  }
  const server = validateServer({
    name: query.get("name") ?? "",
    url: query.get("url") ?? "",
    directAddress: query.get("direct") ?? "",
    tailscaleOnly: tailscale === "1",
  });
  return { ...server, token };
}

export function displayName(server: ServerConfig): string {
  if (server.name) return server.name;
  if (server.url) return new URL(server.url).hostname;
  return server.directAddress || "Cantrip on LAN";
}
