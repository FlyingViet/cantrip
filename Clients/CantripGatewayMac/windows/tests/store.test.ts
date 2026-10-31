import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vitest";
import { SecretBox, SettingsStore } from "../src/main/store";

const box: SecretBox = {
  isEncryptionAvailable: () => true,
  encryptString: (text) => Buffer.from(`enc:${text}`),
  decryptString: (data) => {
    const text = data.toString();
    if (!text.startsWith("enc:")) throw new Error("not ours");
    return text.slice(4);
  },
};
const token = (letter: string) => letter.repeat(40);
const server = (direct: string, name = "") => ({ name, url: "", directAddress: direct, tailscaleOnly: false });
const file = () => join(mkdtempSync(join(tmpdir(), "gw-store-")), "settings.json");

describe("saved Macs", () => {
  it("migrates a version 1 pairing to the selected server", () => {
    const path = file();
    writeFileSync(path, JSON.stringify({ version: 1, server: server("192.168.0.10:55331", "Mini"), token: Buffer.from(`enc:${token("a")}`).toString("base64") }));
    const store = new SettingsStore(path, box);
    const list = store.list();
    expect(list.servers).toHaveLength(1);
    expect(list.selectedID).toBe(list.servers[0].id);
    expect(store.load()?.server.name).toBe("Mini");
  });

  it("keeps a migrated pairing's ID so Remove and Select work on it", () => {
    const path = file();
    writeFileSync(path, JSON.stringify({ version: 1, server: server("192.168.0.10:55331", "Mini"), token: Buffer.from(`enc:${token("a")}`).toString("base64") }));
    const store = new SettingsStore(path, box);
    const shown = store.list().servers[0].id;
    expect(store.list().servers[0].id).toBe(shown);
    expect(JSON.parse(readFileSync(path, "utf8")).version).toBe(2);
    store.select(shown);
    store.remove(shown);
    expect(store.list().servers).toHaveLength(0);
  });

  it("selects a new Mac when asked even if an unreadable entry holds the selection", () => {
    const path = file();
    writeFileSync(path, JSON.stringify({ version: 2, selectedID: "OLD", servers: [{ id: "OLD", server: server("10.0.0.1:1000"), token: Buffer.from("garbage").toString("base64") }] }));
    const store = new SettingsStore(path, box);
    const firstMac = store.list().selectedID === null;
    expect(firstMac).toBe(true);
    const saved = store.add(server("10.0.0.2:2000"), token("b"), { select: firstMac });
    expect(store.list().selectedID).toBe(saved.id);
    expect(store.load()?.token).toBe(token("b"));
  });

  it("selects the first Mac added and keeps the selection when adding more", () => {
    const store = new SettingsStore(file(), box);
    const first = store.add(server("10.0.0.1:1000"), token("a"));
    store.add(server("10.0.0.2:1000"), token("b"));
    expect(store.list().selectedID).toBe(first.id);
    expect(store.list().servers).toHaveLength(2);
  });

  it("updates the Mac with the same addresses instead of adding a duplicate", () => {
    const store = new SettingsStore(file(), box);
    const first = store.add(server("10.0.0.1:1000", "Old"), token("a"));
    const again = store.add(server("10.0.0.1:1000", "New"), token("c"));
    expect(again.id).toBe(first.id);
    expect(store.list().servers).toHaveLength(1);
    expect(store.load()).toEqual({ server: server("10.0.0.1:1000", "New"), token: token("c") });
  });

  it("never writes a token in the clear", () => {
    const path = file();
    new SettingsStore(path, box).add(server("10.0.0.1:1000"), token("z"));
    expect(readFileSync(path, "utf8")).not.toContain(token("z"));
  });

  it("selects, removes and clears", () => {
    const path = file();
    const store = new SettingsStore(path, box);
    const a = store.add(server("10.0.0.1:1000"), token("a"));
    const b = store.add(server("10.0.0.2:1000"), token("b"));
    store.select(b.id);
    expect(store.load()?.token).toBe(token("b"));
    store.remove(b.id);
    expect(store.list().selectedID).toBeNull();
    expect(store.load()).toBeNull();
    store.select(a.id);
    store.remove(a.id);
    expect(store.list().servers).toHaveLength(0);
    expect(() => store.select("missing")).toThrow();
  });

  it("counts servers it can't decrypt", () => {
    const path = file();
    writeFileSync(path, JSON.stringify({ version: 2, selectedID: "X", servers: [{ id: "X", server: server("10.0.0.1:1000"), token: Buffer.from("garbage").toString("base64") }] }));
    const list = new SettingsStore(path, box).list();
    expect(list).toEqual({ servers: [], selectedID: null, unreadable: 1 });
  });
});
