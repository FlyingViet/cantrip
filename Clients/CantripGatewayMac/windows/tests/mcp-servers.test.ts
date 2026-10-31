import { describe, expect, it } from "vitest";
import type { MCPServer } from "../src/gateway/api/types";
import { mcpStatus } from "../src/gateway/ui/sheets/sheetLogic";

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
