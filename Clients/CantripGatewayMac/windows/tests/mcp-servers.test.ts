import { describe, expect, it } from "vitest";
import { mcpBridgeRequest } from "../src/main/mcpBridge";
import type { MCPServer } from "../src/gateway/api/types";
import { mcpConnectLabel, mcpKind, mcpStatus } from "../src/gateway/ui/sheets/sheetLogic";

const server = (patch: Partial<MCPServer>): MCPServer => ({
  name: "maps", remote: true, oauth: true, relayed: true, enabled: true, disabledBackends: [], ...patch,
});

describe("MCP server status", () => {
  it("names each sign-in phase the way the Mac and iPhone do", () => {
    expect(mcpStatus(server({ state: { phase: "awaitingApproval" } }))).toEqual({ text: "Waiting for your OK", tone: "attention" });
    expect(mcpStatus(server({ state: { phase: "ready" } }))).toEqual({ text: "Signed in", tone: "" });
    expect(mcpStatus(server({ state: { phase: "locked" } })).tone).toBe("warning");
    expect(mcpStatus(server({})).text).toBe("Not signed in");
  });

  it("treats local and switched-off servers as not needing a sign-in", () => {
    expect(mcpStatus(server({ oauth: false, remote: false })).text).toBe("Ready");
    expect(mcpStatus(server({ enabled: false })).text).toBe("Off");
  });
});

describe("MCP server rows", () => {
  it("says a credential is in the Mac's keychain, and when a sign-in's token ends", () => {
    expect(mcpStatus(server({ oauth: false, credentials: true })).text).toBe("Credentials in Mac keychain");
    expect(mcpStatus(server({ oauth: false, credentials: false })).text).toBe("Ready");
    expect(mcpStatus(server({ state: { phase: "ready", expiresAt: "2026-11-01T18:30:00Z" } })).text).toMatch(/^Signed in · token until /);
  });

  it("offers Retry after a failed sign-in and tags servers like the Mac", () => {
    expect(mcpConnectLabel(server({ state: { phase: "failed" } }))).toBe("Retry");
    expect(mcpConnectLabel(server({}))).toBe("Connect");
    expect(mcpKind(server({}))).toBe("Remote · via Cantrip");
    expect(mcpKind(server({ remote: false, relayed: false }))).toBe("Local");
  });
});

describe("Settings' MCP bridge", () => {
  it("passes the list and its actions", () => {
    expect(mcpBridgeRequest({ method: "GET" })).toEqual({ method: "GET" });
    expect(mcpBridgeRequest({ method: "POST", body: { action: "connect", name: "maps" } }))
      .toEqual({ method: "POST", body: JSON.stringify({ action: "connect", name: "maps" }) });
    expect(mcpBridgeRequest({ method: "POST", body: { action: "setBackend", name: "maps", backend: "Codex", enabled: false } }))
      .toHaveProperty("method", "POST");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "setEnabled", name: "maps", enabled: true } })).toHaveProperty("method", "POST");
  });

  it("refuses anything else", () => {
    expect(mcpBridgeRequest({ method: "DELETE" })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "GET", body: {} })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "setTab", name: "maps", tab: "x", enabled: true } })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "connect", name: "maps", path: "/api/v1/sessions" } })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "setBackend", name: "maps", backend: "Other", enabled: true } })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "setEnabled", name: "maps", enabled: "yes" } })).toHaveProperty("error");
    expect(mcpBridgeRequest({ method: "POST", body: { action: "connect", name: "" } })).toHaveProperty("error");
  });
});
