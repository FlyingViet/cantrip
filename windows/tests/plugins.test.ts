import { mkdtemp, mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import {
  mergePluginMcpServers,
  parsePluginManifest,
  parsePluginManifestText,
  pluginCapabilitySummary,
  resolveInsidePlugin,
} from "../src/shared/plugins";

const cleanup: string[] = [];

afterEach(async () => {
  await Promise.all(cleanup.splice(0).map((entry) => rm(entry, { recursive: true, force: true })));
});

describe("plugin manifests", () => {
  it("accepts the cross-platform manifest and ignores unknown fields", () => {
    expect(
      parsePluginManifest({
        name: "Dashboard",
        futureField: true,
        panel: { html: "index.html", capabilities: ["cantripStatus"] },
      }),
    ).toMatchObject({
      name: "Dashboard",
      panel: { html: "index.html", capabilities: ["cantripStatus"] },
    });
    expect(parsePluginManifest({ description: "missing name" })).toBeNull();
    expect(parsePluginManifestText('\uFEFF{"name":"Windows BOM"}')?.name).toBe(
      "Windows BOM",
    );
  });

  it("shows every privileged declaration in the approval summary", () => {
    const manifest = parsePluginManifest({
      name: "Everything",
      panel: {
        html: "panel.html",
        capabilities: ["cantripStatus", "cantripActions"],
      },
      dataSources: {
        events: { command: "scripts/events.ps1", args: ["--today"] },
      },
      mcpServers: {
        search: { command: "node", args: ["server.js"] },
      },
    })!;
    expect(pluginCapabilitySummary(manifest)).toEqual([
      "Dashboard: panel.html",
      expect.stringContaining("Capability cantripStatus"),
      expect.stringContaining("Capability cantripActions"),
      "Data source events: scripts/events.ps1 --today",
      "MCP server search: node server.js",
    ]);
  });

  it("merges colliding MCP names without dropping either server", () => {
    const first = parsePluginManifest({
      name: "Alpha",
      mcpServers: { "web search": { command: "alpha.exe" } },
    })!;
    const second = parsePluginManifest({
      name: "Beta",
      mcpServers: { "web search": { command: "beta.exe" } },
    })!;
    expect(
      mergePluginMcpServers([
        { id: "alpha", name: "Alpha", manifest: first },
        { id: "beta-plugin", name: "Beta", manifest: second },
      ]),
    ).toEqual({
      web_search: { command: "alpha.exe", args: undefined, env: undefined },
      "beta-plugin_web_search": {
        command: "beta.exe",
        args: undefined,
        env: undefined,
      },
    });
  });

  it("rejects path traversal outside a plugin folder", async () => {
    const parent = await mkdtemp(path.join(tmpdir(), "cantrip-plugin-test-"));
    cleanup.push(parent);
    const root = path.join(parent, "plugin");
    await mkdir(root);
    await writeFile(path.join(root, "panel.html"), "ok");
    await writeFile(path.join(parent, "secret.txt"), "secret");

    await expect(resolveInsidePlugin(root, "panel.html")).resolves.toBe(
      path.join(root, "panel.html"),
    );
    await expect(resolveInsidePlugin(root, "..\\secret.txt")).rejects.toThrow(
      "escapes its directory",
    );
  });
});
