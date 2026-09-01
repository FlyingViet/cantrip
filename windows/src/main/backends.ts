import { execFile, spawn, type ChildProcessWithoutNullStreams } from "node:child_process";
import { existsSync, readFileSync } from "node:fs";
import { mkdir, rm, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import path from "node:path";
import { StringDecoder } from "node:string_decoder";
import { promisify } from "node:util";
import type {
  BackendId,
  BackendStatus,
  RunChunkEvent,
  RunExitEvent,
  RunRequest,
} from "../shared/types";
import type { PluginMcpSnapshot } from "../shared/pluginTypes";

const execFileAsync = promisify(execFile);
const ansiPattern =
  // eslint-disable-next-line no-control-regex
  /[\u001B\u009B][[\]()#;?]*(?:(?:(?:[a-zA-Z\d]*(?:;[-a-zA-Z\d/#&.:=?%@~_]+)*)?\u0007)|(?:(?:\d{1,4}(?:;\d{0,4})*)?[\dA-PR-TZcf-nq-uy=><~]))/g;

interface CommandSpec {
  executable: string;
  prefixArgs: string[];
}

const labels: Record<BackendId, string> = {
  claude: "Claude Code",
  copilot: "GitHub Copilot",
  codex: "OpenAI Codex",
};

async function where(command: string): Promise<string[]> {
  try {
    const { stdout } = await execFileAsync("where.exe", [command], {
      windowsHide: true,
      timeout: 5_000,
    });
    return stdout
      .split(/\r?\n/)
      .map((entry) => entry.trim())
      .filter(Boolean);
  } catch {
    return [];
  }
}

async function commandSpec(command: string): Promise<CommandSpec | null> {
  const matches = await where(command);
  const native = matches.find((file) => [".exe", ".com"].includes(path.extname(file).toLocaleLowerCase()));
  if (native) return { executable: native, prefixArgs: [] };

  const shim = matches.find((file) => [".cmd", ".bat"].includes(path.extname(file).toLocaleLowerCase()));
  if (!shim || !existsSync(shim)) return null;

  const contents = readFileSync(shim, "utf8");
  const scriptMatch = contents.match(/"%dp0%\\([^"]+?\.js)"/i);
  if (!scriptMatch) return null;
  const script = path.resolve(path.dirname(shim), scriptMatch[1]);
  if (!existsSync(script)) return null;

  const localNode = path.join(path.dirname(shim), "node.exe");
  const node = existsSync(localNode) ? localNode : (await where("node")).find((file) => file.endsWith(".exe"));
  return node ? { executable: node, prefixArgs: [script] } : null;
}

export function backendArgs(
  request: RunRequest,
  attachmentPaths: string[] = [],
  pluginMcp: PluginMcpSnapshot | null = null,
): string[] {
  const model = request.model.trim();
  const effort = request.effort.trim();
  const contextTier = request.contextTier.trim();
  const claudePrompt = attachmentPaths.length
    ? `${request.prompt}\n\nScreen context is available at:\n${attachmentPaths
        .map((attachment) => `- ${attachment}`)
        .join("\n")}\nInspect these images before answering.`
    : request.prompt;

  switch (request.backend) {
    case "claude":
      return [
        "-p",
        claudePrompt,
        "--output-format",
        "text",
        ...(request.allowActions
          ? ["--dangerously-skip-permissions"]
          : ["--permission-mode", "plan"]),
        ...(model ? ["--model", model] : []),
        ...(effort ? ["--effort", effort] : []),
        ...(attachmentPaths.length
          ? ["--add-dir", path.dirname(attachmentPaths[0])]
          : []),
        ...(pluginMcp ? ["--mcp-config", pluginMcp.configPath] : []),
      ];
    case "copilot":
      return [
        "--prompt",
        request.prompt,
        "--output-format",
        "text",
        "--no-color",
        "--no-ask-user",
        ...(request.allowActions ? ["--allow-all-tools"] : ["--mode", "plan"]),
        ...(model ? ["--model", model] : []),
        ...(effort ? ["--reasoning-effort", effort] : []),
        ...(contextTier ? ["--context", contextTier] : []),
        ...attachmentPaths.flatMap((attachment) => ["--attachment", attachment]),
      ];
    case "codex":
      return [
        "exec",
        "--color",
        "never",
        ...(model ? ["--model", model] : []),
        ...(effort
          ? ["--config", `model_reasoning_effort="${effort}"`]
          : []),
        ...(pluginMcp ? codexMcpArguments(pluginMcp) : []),
        ...attachmentPaths.flatMap((attachment) => ["--image", attachment]),
        ...(request.allowActions
          ? ["--dangerously-bypass-approvals-and-sandbox"]
          : ["--sandbox", "read-only"]),
        request.prompt,
      ];
  }
}

function tomlString(value: string): string {
  return JSON.stringify(value);
}

export function codexMcpArguments(snapshot: PluginMcpSnapshot): string[] {
  const args: string[] = [];
  for (const [name, server] of Object.entries(snapshot.servers)) {
    args.push("--config", `mcp_servers.${name}.command=${tomlString(server.command)}`);
    if (server.args?.length) {
      args.push(
        "--config",
        `mcp_servers.${name}.args=[${server.args.map(tomlString).join(",")}]`,
      );
    }
    if (server.env && Object.keys(server.env).length) {
      const entries = Object.entries(server.env)
        .map(([key, value]) => `${tomlString(key)}=${tomlString(value)}`)
        .join(",");
      args.push("--config", `mcp_servers.${name}.env={${entries}}`);
    }
  }
  return args;
}

export class RunManager {
  private readonly processes = new Map<string, ChildProcessWithoutNullStreams>();
  private readonly specs = new Map<BackendId, CommandSpec | null>();
  private readonly attachmentDirectories = new Map<string, string>();
  private mcpProvider: (() => PluginMcpSnapshot | null) | null = null;

  setMcpProvider(provider: () => PluginMcpSnapshot | null): void {
    this.mcpProvider = provider;
  }

  async cleanupStaleAttachments(): Promise<void> {
    await rm(path.join(tmpdir(), "Cantrip"), { recursive: true, force: true });
  }

  async statuses(): Promise<BackendStatus[]> {
    const ids: BackendId[] = ["claude", "copilot", "codex"];
    return Promise.all(
      ids.map(async (id) => {
        const spec = await this.resolve(id);
        return {
          id,
          label: labels[id],
          available: spec !== null,
          detail: spec ? spec.executable : `${id} was not found on PATH`,
        };
      }),
    );
  }

  async start(
    request: RunRequest,
    onChunk: (event: RunChunkEvent) => void,
    onExit: (event: RunExitEvent) => void,
  ): Promise<{ ok: boolean; error?: string }> {
    const validationError = this.validate(request);
    if (validationError) return { ok: false, error: validationError };
    if (this.processes.has(request.runId)) {
      return { ok: false, error: "That run is already active." };
    }

    let attachmentDirectory: string | null = null;
    let attachmentPaths: string[] = [];
    if (request.mode === "ai" && request.attachments.length) {
      try {
        const materialized = await this.materializeAttachments(request);
        attachmentDirectory = materialized.directory;
        attachmentPaths = materialized.paths;
        this.attachmentDirectories.set(request.runId, materialized.directory);
      } catch (error) {
        return {
          ok: false,
          error: error instanceof Error ? error.message : String(error),
        };
      }
    }

    let executable: string;
    let args: string[];
    if (request.mode === "shell") {
      executable = "powershell.exe";
      args = ["-NoLogo", "-NoProfile", "-NonInteractive", "-Command", request.prompt];
    } else {
      const spec = await this.resolve(request.backend);
      if (!spec) return { ok: false, error: `${labels[request.backend]} is not installed or is not on PATH.` };
      executable = spec.executable;
      args = [
        ...spec.prefixArgs,
        ...backendArgs(request, attachmentPaths, this.mcpProvider?.() ?? null),
      ];
    }

    let child: ChildProcessWithoutNullStreams;
    try {
      child = spawn(executable, args, {
        cwd: request.workdir,
        windowsHide: true,
        shell: false,
        env: { ...process.env, NO_COLOR: "1", TERM: "dumb" },
      });
    } catch (error) {
      if (attachmentDirectory) {
        void rm(attachmentDirectory, { recursive: true, force: true });
        this.attachmentDirectories.delete(request.runId);
      }
      return { ok: false, error: error instanceof Error ? error.message : String(error) };
    }

    this.processes.set(request.runId, child);
    const stdoutDecoder = new StringDecoder("utf8");
    const stderrDecoder = new StringDecoder("utf8");
    let spawnError: string | undefined;

    child.stdout.on("data", (data: Buffer) => {
      const text = stdoutDecoder.write(data).replace(ansiPattern, "");
      if (text) onChunk({ runId: request.runId, stream: "stdout", text });
    });
    child.stderr.on("data", (data: Buffer) => {
      const text = stderrDecoder.write(data).replace(ansiPattern, "");
      if (text) onChunk({ runId: request.runId, stream: "stderr", text });
    });
    child.on("error", (error) => {
      spawnError = error.message;
    });
    child.on("close", (exitCode) => {
      const stdoutTail = stdoutDecoder.end().replace(ansiPattern, "");
      const stderrTail = stderrDecoder.end().replace(ansiPattern, "");
      if (stdoutTail) onChunk({ runId: request.runId, stream: "stdout", text: stdoutTail });
      if (stderrTail) onChunk({ runId: request.runId, stream: "stderr", text: stderrTail });
      this.processes.delete(request.runId);
      if (attachmentDirectory) {
        void rm(attachmentDirectory, { recursive: true, force: true });
        this.attachmentDirectories.delete(request.runId);
      }
      onExit({ runId: request.runId, exitCode, error: spawnError });
    });

    return { ok: true };
  }

  cancel(runId: string): boolean {
    const child = this.processes.get(runId);
    if (!child) return false;
    return child.kill();
  }

  cancelAll(): void {
    for (const child of this.processes.values()) child.kill();
    this.processes.clear();
    for (const directory of this.attachmentDirectories.values()) {
      void rm(directory, { recursive: true, force: true });
    }
    this.attachmentDirectories.clear();
  }

  private async resolve(id: BackendId): Promise<CommandSpec | null> {
    if (this.specs.has(id)) return this.specs.get(id) ?? null;
    const spec = await commandSpec(id);
    this.specs.set(id, spec);
    return spec;
  }

  private validate(request: RunRequest): string | null {
    if (!/^[a-f0-9-]{16,64}$/i.test(request.runId)) return "Invalid run identifier.";
    if (!request.prompt.trim()) return "The command or prompt is empty.";
    if (request.prompt.length > 32_000) return "The command or prompt is too long.";
    if (!path.isAbsolute(request.workdir) || !existsSync(request.workdir)) {
      return "Choose an existing working directory.";
    }
    if (!["ai", "shell"].includes(request.mode)) return "Invalid run mode.";
    if (!["claude", "copilot", "codex"].includes(request.backend)) return "Invalid backend.";
    if (
      request.model.length > 100 ||
      (request.model && !/^[a-zA-Z0-9._:/[\]-]+$/.test(request.model))
    ) {
      return "Invalid model identifier.";
    }
    if (
      !["", "none", "minimal", "low", "medium", "high", "xhigh", "max"].includes(
        request.effort,
      )
    ) {
      return "Invalid reasoning effort.";
    }
    if (!["", "default", "long_context"].includes(request.contextTier)) {
      return "Invalid context tier.";
    }
    if (!Array.isArray(request.attachments) || request.attachments.length > 6) {
      return "Too many screen attachments.";
    }
    for (const attachment of request.attachments) {
      if (
        typeof attachment.name !== "string" ||
        attachment.name.length > 100 ||
        typeof attachment.dataUrl !== "string" ||
        attachment.dataUrl.length > 20_000_000 ||
        !attachment.dataUrl.startsWith("data:image/png;base64,")
      ) {
        return "Invalid screen attachment.";
      }
    }
    return null;
  }

  private async materializeAttachments(
    request: RunRequest,
  ): Promise<{ directory: string; paths: string[] }> {
    const directory = path.join(tmpdir(), "Cantrip", request.runId);
    await mkdir(directory, { recursive: true });
    const paths: string[] = [];
    try {
      for (const [index, attachment] of request.attachments.entries()) {
        const bytes = Buffer.from(attachment.dataUrl.slice("data:image/png;base64,".length), "base64");
        if (bytes.length > 12_000_000) throw new Error("A screen capture is too large.");
        const filePath = path.join(directory, `screen-${index + 1}.png`);
        await writeFile(filePath, bytes, { flag: "wx" });
        paths.push(filePath);
      }
      return { directory, paths };
    } catch (error) {
      await rm(directory, { recursive: true, force: true });
      throw error;
    }
  }
}
