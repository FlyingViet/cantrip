import type {
  PluginDataSourceManifest,
  PluginManifest,
  PluginMcpServerManifest,
} from "./pluginTypes";
import { realpath } from "node:fs/promises";
import path from "node:path";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stringArray(value: unknown): string[] | undefined {
  if (!Array.isArray(value)) return undefined;
  return value.filter((entry): entry is string => typeof entry === "string");
}

function stringRecord(value: unknown): Record<string, string> | undefined {
  if (!isRecord(value)) return undefined;
  const entries = Object.entries(value).filter(
    (entry): entry is [string, string] => typeof entry[1] === "string",
  );
  return Object.fromEntries(entries);
}

export function parsePluginManifest(value: unknown): PluginManifest | null {
  if (!isRecord(value) || typeof value.name !== "string" || !value.name.trim()) {
    return null;
  }

  let panel: PluginManifest["panel"];
  if (isRecord(value.panel) && typeof value.panel.html === "string") {
    panel = {
      html: value.panel.html,
      title: typeof value.panel.title === "string" ? value.panel.title : undefined,
      capabilities: stringArray(value.panel.capabilities),
    };
  }

  const dataSources: Record<string, PluginDataSourceManifest> = {};
  if (isRecord(value.dataSources)) {
    for (const [name, source] of Object.entries(value.dataSources)) {
      if (!isRecord(source) || typeof source.command !== "string") continue;
      dataSources[name] = {
        command: source.command,
        args: stringArray(source.args),
        timeoutSeconds:
          typeof source.timeoutSeconds === "number" ? source.timeoutSeconds : undefined,
      };
    }
  }

  const mcpServers: Record<string, PluginMcpServerManifest> = {};
  if (isRecord(value.mcpServers)) {
    for (const [name, server] of Object.entries(value.mcpServers)) {
      if (!isRecord(server) || typeof server.command !== "string") continue;
      mcpServers[name] = {
        command: server.command,
        args: stringArray(server.args),
        env: stringRecord(server.env),
      };
    }
  }

  return {
    name: value.name.trim(),
    version: typeof value.version === "string" ? value.version : undefined,
    description:
      typeof value.description === "string" ? value.description : undefined,
    panel,
    dataSources: Object.keys(dataSources).length ? dataSources : undefined,
    mcpServers: Object.keys(mcpServers).length ? mcpServers : undefined,
  };
}

export function parsePluginManifestText(text: string): PluginManifest | null {
  return parsePluginManifest(JSON.parse(text.replace(/^\uFEFF/, "")) as unknown);
}

const capabilityDescriptions: Record<string, string> = {
  cantripStatus: "Read Cantrip build, backend, and update status",
  cantripActions: "Request fixed Cantrip update, relaunch, repo, and log actions",
  dailyBriefing: "Read calendar, mail, and message briefing data (not available on Windows yet)",
};

export function pluginCapabilitySummary(manifest: PluginManifest): string[] {
  const summary: string[] = [];
  if (manifest.panel) {
    summary.push(`Dashboard: ${manifest.panel.html}`);
    for (const capability of manifest.panel.capabilities ?? []) {
      summary.push(
        `Capability ${capability}: ${capabilityDescriptions[capability] ?? "Plugin-declared native access"}`,
      );
    }
  }
  for (const [name, source] of Object.entries(manifest.dataSources ?? {})) {
    summary.push(
      `Data source ${name}: ${[source.command, ...(source.args ?? [])].join(" ")}`,
    );
  }
  for (const [name, server] of Object.entries(manifest.mcpServers ?? {})) {
    summary.push(
      `MCP server ${name}: ${[server.command, ...(server.args ?? [])].join(" ")}`,
    );
  }
  return summary;
}

export function sanitizeMcpServerName(name: string): string {
  return name.replace(/[^a-zA-Z0-9_-]/g, "_") || "server";
}

export function mergePluginMcpServers(
  plugins: Array<{ id: string; name: string; manifest: PluginManifest }>,
): Record<string, PluginMcpServerManifest> {
  const merged: Record<string, PluginMcpServerManifest> = {};
  for (const plugin of [...plugins].sort((left, right) =>
    left.name.localeCompare(right.name, undefined, { sensitivity: "base" }),
  )) {
    for (const [rawName, server] of Object.entries(plugin.manifest.mcpServers ?? {})) {
      let name = sanitizeMcpServerName(rawName);
      if (merged[name]) {
        name = `${sanitizeMcpServerName(plugin.id)}_${name}`;
      }
      let suffix = 2;
      const base = name;
      while (merged[name]) {
        name = `${base}_${suffix}`;
        suffix += 1;
      }
      merged[name] = server;
    }
  }
  return merged;
}

export async function resolveInsidePlugin(
  root: string,
  candidate: string,
): Promise<string> {
  const resolvedRoot = await realpath(root);
  const resolvedCandidate = await realpath(path.resolve(root, candidate));
  const relative = path.relative(resolvedRoot, resolvedCandidate);
  if (
    !relative ||
    relative.startsWith("..") ||
    path.isAbsolute(relative)
  ) {
    if (resolvedCandidate === resolvedRoot) {
      throw new Error("Plugin path must identify a file.");
    }
    throw new Error("Plugin path escapes its directory.");
  }
  return resolvedCandidate;
}
