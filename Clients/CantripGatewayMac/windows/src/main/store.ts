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

interface StoredFile {
  version: 1;
  server: ServerConfig;
  /** base64 of the encrypted token; never the token itself. */
  token: string;
}

export class SettingsStore {
  constructor(private readonly file: string, private readonly box: SecretBox) {}

  load(): Pairing | null {
    if (!existsSync(this.file)) return null;
    let stored: StoredFile;
    try {
      stored = JSON.parse(readFileSync(this.file, "utf8"));
    } catch {
      return null;
    }
    if (stored?.version !== 1 || typeof stored.token !== "string") return null;
    try {
      const server = validateServer(stored.server);
      const token = validateToken(this.box.decryptString(Buffer.from(stored.token, "base64")));
      return { server, token };
    } catch {
      // Unreadable (another Windows user, a reset profile): pair again.
      return null;
    }
  }

  save(server: ServerConfig, token: string): Pairing {
    if (!this.box.isEncryptionAvailable()) {
      throw new Error("Windows can't encrypt the pairing token for this account, so it wasn't saved.");
    }
    const pairing = { server: validateServer(server), token: validateToken(token) };
    const stored: StoredFile = {
      version: 1,
      server: pairing.server,
      token: this.box.encryptString(pairing.token).toString("base64"),
    };
    mkdirSync(dirname(this.file), { recursive: true });
    const temporary = `${this.file}.tmp`;
    writeFileSync(temporary, JSON.stringify(stored, null, 2), { mode: 0o600 });
    renameSync(temporary, this.file);
    return pairing;
  }

  clear(): void {
    rmSync(this.file, { force: true });
  }
}
