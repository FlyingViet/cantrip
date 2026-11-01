// MCP Servers (CantripMCPServersView, CantripMCPServers.swift): the servers Cantrip on the Mac shares
// with every backend and their sign-ins, with this tab's own switches. Connect opens the consent page
// in the Mac's agent Chrome; this sheet shows it and approves it. Tokens never leave the Mac.
import type { JSX } from "preact";
import { api } from "../../api/client";
import type { MCPSnapshot } from "../../api/types";
import * as remote from "../../state/remote";
import { Sheet } from "../kit";
import { MCPServerList, type MCPTransport } from "./MCPServerList";

const transport: MCPTransport = {
  load: (tabID) => api<MCPSnapshot>(`/api/v1/mcp${tabID ? `?tab=${encodeURIComponent(tabID)}` : ""}`),
  act: (body) => remote.mutate(() => api<MCPSnapshot>("/api/v1/mcp", { method: "POST", body })),
};

export function MCPServersSheet(props: { tabID?: string; onClose: () => void }): JSX.Element {
  return (
    <Sheet title="MCP Servers" onClose={props.onClose} width={680} height={640}>
      <MCPServerList transport={transport} tabID={props.tabID} />
    </Sheet>
  );
}
