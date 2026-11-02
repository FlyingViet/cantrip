import { existsSync, mkdirSync, readFileSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import { validateServer, validateToken } from "./pairing";
import type { ServerConfig } from "./pairing";

/** Electron's safeStorage (DPAPI on Windows); injected so tests can fake it. */
export interface SecretBox {
  isEncryptionAvailable(): boolean;
  encryptString(text: string): Buffer;
  decryptString(data: Buffer): string;
}

export interface Pairing {
  server: ServerConfig;
  token: string;
}

interface StoredPairing {
  version: 1;
  server: ServerConfig;
  /** base64 of the encrypted token; never the token itself. */
  token: string;
}

/** The one Mac this PC reads Cantrip Home from. The encrypted file is the token's only copy. */
export class PairingStore {
  constructor(private readonly file: string, private readonly box: SecretBox) {}

  /** The saved pairing; null when none, or when this Windows account can't decrypt it. */
  load(): Pairing | null {
    if (!existsSync(this.file)) return null;
    try {
      const stored = JSON.parse(readFileSync(this.file, "utf8")) as StoredPairing;
      if (stored?.version !== 1 || typeof stored.token !== "string") return null;
      return {
        server: validateServer(stored.server),
        token: validateToken(this.box.decryptString(Buffer.from(stored.token, "base64"))),
      };
    } catch {
      return null;
    }
  }

  save(server: ServerConfig, token: string): Pairing {
    if (!this.box.isEncryptionAvailable()) {
      throw new Error("Windows can't encrypt the pairing token for this account, so it wasn't saved.");
    }
    const pairing = { server: validateServer(server), token: validateToken(token) };
    const stored: StoredPairing = {
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
