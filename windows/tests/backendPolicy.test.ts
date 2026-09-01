import { describe, expect, it } from "vitest";
import { backendArgs } from "../src/main/backends";
import { codexMcpArguments } from "../src/main/backends";
import type { BackendId, RunRequest } from "../src/shared/types";

function request(backend: BackendId, allowActions: boolean): RunRequest {
  return {
    runId: "00000000-0000-4000-8000-000000000000",
    mode: "ai",
    prompt: "Explain the project",
    backend,
    workdir: "C:\\project",
    allowActions,
    model: "",
    effort: "",
    contextTier: "",
    attachments: [],
  };
}

describe("backend action policy", () => {
  it("keeps Claude in plan mode unless actions are enabled", () => {
    expect(backendArgs(request("claude", false))).toContain("plan");
    expect(backendArgs(request("claude", false))).not.toContain(
      "--dangerously-skip-permissions",
    );
    expect(backendArgs(request("claude", true))).toContain(
      "--dangerously-skip-permissions",
    );
  });

  it("does not grant Copilot tools unless actions are enabled", () => {
    expect(backendArgs(request("copilot", false))).toContain("plan");
    expect(backendArgs(request("copilot", false))).not.toContain("--allow-all-tools");
    expect(backendArgs(request("copilot", true))).toContain("--allow-all-tools");
  });

  it("keeps Codex read-only unless actions are enabled", () => {
    expect(backendArgs(request("codex", false))).toContain("read-only");
    expect(backendArgs(request("codex", false))).not.toContain(
      "--dangerously-bypass-approvals-and-sandbox",
    );
    expect(backendArgs(request("codex", true))).toContain(
      "--dangerously-bypass-approvals-and-sandbox",
    );
  });

  it("passes model, effort, and context flags supported by each backend", () => {
    const claude = {
      ...request("claude", false),
      model: "sonnet",
      effort: "high" as const,
      contextTier: "long_context" as const,
    };
    expect(backendArgs(claude)).toEqual(
      expect.arrayContaining(["--model", "sonnet", "--effort", "high"]),
    );
    expect(backendArgs(claude)).not.toContain("--context");

    const copilot = {
      ...request("copilot", false),
      model: "gpt-5.6-sol",
      effort: "xhigh" as const,
      contextTier: "long_context" as const,
    };
    expect(backendArgs(copilot)).toEqual(
      expect.arrayContaining([
        "--model",
        "gpt-5.6-sol",
        "--reasoning-effort",
        "xhigh",
        "--context",
        "long_context",
      ]),
    );

    const codex = {
      ...request("codex", false),
      model: "gpt-5.4",
      effort: "medium" as const,
    };
    expect(backendArgs(codex)).toEqual(
      expect.arrayContaining([
        "--model",
        "gpt-5.4",
        "--config",
        'model_reasoning_effort="medium"',
      ]),
    );
  });

  it("passes screen captures through each backend's supported mechanism", () => {
    const paths = ["C:\\Temp\\Cantrip\\run\\screen-1.png"];
    const claude = backendArgs(request("claude", false), paths);
    expect(claude).toEqual(expect.arrayContaining(["--add-dir", "C:\\Temp\\Cantrip\\run"]));
    expect(claude.join(" ")).toContain("screen-1.png");

    expect(backendArgs(request("copilot", false), paths)).toEqual(
      expect.arrayContaining(["--attachment", paths[0]]),
    );
    expect(backendArgs(request("codex", false), paths)).toEqual(
      expect.arrayContaining(["--image", paths[0]]),
    );
  });

  it("passes approved plugin MCP servers to Claude and Codex", () => {
    const snapshot = {
      configPath: "C:\\Users\\me\\AppData\\Roaming\\cantrip\\plugin-mcp.json",
      servers: {
        search: {
          command: "node",
          args: ["C:\\Plugin Files\\server.js"],
          env: { API_MODE: "local" },
        },
      },
    };
    expect(backendArgs(request("claude", false), [], snapshot)).toEqual(
      expect.arrayContaining(["--mcp-config", snapshot.configPath]),
    );
    expect(codexMcpArguments(snapshot)).toEqual(
      expect.arrayContaining([
        "--config",
        'mcp_servers.search.command="node"',
        'mcp_servers.search.args=["C:\\\\Plugin Files\\\\server.js"]',
        'mcp_servers.search.env={"API_MODE"="local"}',
      ]),
    );
  });
});
