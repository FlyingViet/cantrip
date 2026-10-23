import { createHash, randomUUID } from "node:crypto";
import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { ServerConfig, validateServer, validateToken } from "./pairing";

/** Electron's safeStorage (DPAPI on Windows, Keychain on macOS); injected so tests can fake it. */
export interface SecretBox {
  isEncryptionAvailable(): boolean;
  encryptString(text: string): Buffer;
  decryptString(data: Buffer): string;
}

export interface Pairing {
  server: ServerConfig;
  token: string;
}

/** One saved Mac, like the Mac app's saved Cantrip Remote servers. */
export interface SavedServer extends Pairing {
  id: string;
}

export interface ServerList {
  servers: SavedServer[];
  /** The Mac this PC connects to; null when none is selected. */
  selectedID: string | null;
  /** Saved servers whose token can't be decrypted here (another Windows user, a reset profile). */
  unreadable: number;
}

interface StoredServer {
  id: string;
  server: ServerConfig;
  /** base64 of the encrypted token; never the token itself. */
  token: string;
}

interface StoredFileV1 {
  version: 1;
  server: ServerConfig;
  token: string;
}

interface StoredFileV2 {
  version: 2;
  selectedID: string | null;
  servers: StoredServer[];
}

/** A fixed ID for a migrated version 1 pairing, from its addresses. */
function migratedID(server: Partial<ServerConfig> | undefined): string {
  const hex = createHash("sha256").update(JSON.stringify([server?.url ?? "", server?.directAddress ?? ""])).digest("hex").toUpperCase();
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20, 32)}`;
}

export class SettingsStore {
  constructor(private readonly file: string, private readonly box: SecretBox) {}

  private readFile(): StoredFileV2 {
    if (!existsSync(this.file)) return { version: 2, selectedID: null, servers: [] };
    let stored: StoredFileV1 | StoredFileV2;
    try {
      stored = JSON.parse(readFileSync(this.file, "utf8"));
    } catch {
      return { version: 2, selectedID: null, servers: [] };
    }
    // Version 1 held one pairing: it becomes the selected server, saved at once so its ID stays
    // the same for Settings' Select/Remove.
    if (stored?.version === 1 && typeof stored.token === "string") {
      const id = migratedID(stored.server);
      const migrated: StoredFileV2 = { version: 2, selectedID: id, servers: [{ id, server: stored.server, token: stored.token }] };
      try { this.writeFile(migrated); } catch { /* the ID is stable without the write */ }
      return migrated;
    }
    if (stored?.version !== 2 || !Array.isArray(stored.servers)) return { version: 2, selectedID: null, servers: [] };
    return stored;
  }

  private writeFile(stored: StoredFileV2): void {
    mkdirSync(dirname(this.file), { recursive: true });
    const temporary = `${this.file}.tmp`;
    writeFileSync(temporary, JSON.stringify(stored, null, 2), { mode: 0o600 });
    renameSync(temporary, this.file);
  }

  list(): ServerList {
    const stored = this.readFile();
    const servers: SavedServer[] = [];
    let unreadable = 0;
    for (const entry of stored.servers) {
      try {
        servers.push({
          id: String(entry.id),
          server: validateServer(entry.server),
          token: validateToken(this.box.decryptString(Buffer.from(entry.token, "base64"))),
        });
      } catch {
        unreadable++;
      }
    }
    const selectedID = servers.some((server) => server.id === stored.selectedID) ? stored.selectedID : null;
    return { servers, selectedID, unreadable };
  }

  /** The selected Mac's pairing, or null. */
  load(): Pairing | null {
    const list = this.list();
    const selected = list.servers.find((server) => server.id === list.selectedID);
    return selected ? { server: selected.server, token: selected.token } : null;
  }

  private encrypt(token: string): string {
    if (!this.box.isEncryptionAvailable()) {
      throw new Error("Windows can't encrypt the pairing token for this account, so it wasn't saved.");
    }
    return this.box.encryptString(validateToken(token)).toString("base64");
  }

  /**
   * Adds a Mac, or updates the saved one with the same addresses. It becomes the selected Mac when
   * asked to or when nothing is selected.
   */
  add(server: ServerConfig, token: string, options: { select?: boolean } = {}): SavedServer {
    const stored = this.readFile();
    const config = validateServer(server);
    const entry: StoredServer = { id: randomUUID().toUpperCase(), server: config, token: this.encrypt(token) };
    const same = stored.servers.findIndex((item) =>
      item.server.url === config.url && item.server.directAddress === config.directAddress);
    if (same >= 0) {
      entry.id = stored.servers[same].id;
      stored.servers[same] = entry;
    } else {
      stored.servers.push(entry);
    }
    if (options.select || !stored.selectedID || !stored.servers.some((item) => item.id === stored.selectedID)) {
      stored.selectedID = entry.id;
    }
    this.writeFile(stored);
    return { id: entry.id, server: config, token: validateToken(token) };
  }

  select(id: string | null): void {
    const stored = this.readFile();
    if (id !== null && !stored.servers.some((item) => item.id === id)) throw new Error("That saved Mac no longer exists.");
    stored.selectedID = id;
    this.writeFile(stored);
  }

  remove(id: string): void {
    const stored = this.readFile();
    stored.servers = stored.servers.filter((item) => item.id !== id);
    if (stored.selectedID === id) stored.selectedID = null;
    if (stored.servers.length) this.writeFile(stored);
    else this.clear();
  }

  clear(): void {
    rmSync(this.file, { force: true });
  }
}
