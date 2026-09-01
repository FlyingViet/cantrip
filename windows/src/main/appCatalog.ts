import { createHash } from "node:crypto";
import { promises as fs } from "node:fs";
import path from "node:path";
import { shell } from "electron";
import { rankApps } from "../shared/search";
import type { AppMatch } from "../shared/types";

const shortcutExtensions = new Set([".lnk", ".url", ".appref-ms"]);

async function walk(root: string, depth = 0): Promise<string[]> {
  if (depth > 12) return [];
  let entries;
  try {
    entries = await fs.readdir(root, { withFileTypes: true });
  } catch {
    return [];
  }

  const files: string[] = [];
  for (const entry of entries) {
    const fullPath = path.join(root, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(fullPath, depth + 1)));
    } else {
      files.push(fullPath);
    }
  }
  return files;
}

function displayName(filePath: string): string {
  return path
    .basename(filePath, path.extname(filePath))
    .replace(/\s+\((?:x64|x86|64-bit|32-bit)\)$/i, "")
    .trim();
}

function idFor(filePath: string): string {
  return createHash("sha256").update(filePath.toLocaleLowerCase()).digest("hex").slice(0, 16);
}

export class AppCatalog {
  private apps: AppMatch[] = [];
  private byId = new Map<string, AppMatch>();

  async refresh(): Promise<void> {
    const startMenuRoots = [
      process.env.APPDATA &&
        path.join(process.env.APPDATA, "Microsoft", "Windows", "Start Menu", "Programs"),
      process.env.ProgramData &&
        path.join(process.env.ProgramData, "Microsoft", "Windows", "Start Menu", "Programs"),
    ].filter((root): root is string => Boolean(root));

    const windowsAppsRoot =
      process.env.LOCALAPPDATA &&
      path.join(process.env.LOCALAPPDATA, "Microsoft", "WindowsApps");

    const startMenuFiles = (await Promise.all(startMenuRoots.map((root) => walk(root)))).flat();
    const aliasFiles = windowsAppsRoot ? await walk(windowsAppsRoot, 1) : [];
    const candidatePaths = [
      ...startMenuFiles.filter((file) => shortcutExtensions.has(path.extname(file).toLocaleLowerCase())),
      ...aliasFiles.filter((file) => path.extname(file).toLocaleLowerCase() === ".exe"),
    ];

    const deduplicated = new Map<string, AppMatch>();
    for (const filePath of candidatePaths) {
      const name = displayName(filePath);
      if (!name || /uninstall|readme|documentation|help/i.test(name)) continue;
      const key = name.toLocaleLowerCase();
      const app: AppMatch = {
        id: idFor(filePath),
        name,
        path: filePath,
        kind: shortcutExtensions.has(path.extname(filePath).toLocaleLowerCase())
          ? "shortcut"
          : "executable",
      };
      const existing = deduplicated.get(key);
      if (!existing || app.kind === "shortcut") deduplicated.set(key, app);
    }

    this.apps = [...deduplicated.values()];
    this.byId = new Map(this.apps.map((app) => [app.id, app]));
  }

  search(query: string, limit = 7): AppMatch[] {
    return rankApps(query, this.apps).slice(0, limit);
  }

  async launch(id: string): Promise<{ ok: boolean; error?: string }> {
    const app = this.byId.get(id);
    if (!app) return { ok: false, error: "Unknown app selection." };

    const error = await shell.openPath(app.path);
    return error ? { ok: false, error } : { ok: true };
  }
}
