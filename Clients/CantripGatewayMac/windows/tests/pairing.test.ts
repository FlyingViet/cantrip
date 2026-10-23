import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { displayName, normalizeDirectAddress, normalizeURL, PairingError, parsePairingLink, validateServer } from "../src/main/pairing";
import { SecretBox, SettingsStore } from "../src/main/store";

const TOKEN = "AbCd_efgh-1234567890ijklmnopqrstuvwx";
const link = (query: string) => `cantripagent://pair?${query}`;

describe("parsePairingLink", () => {
  it("reads what cantrip pair --direct prints", () => {
    const parsed = parsePairingLink(link(`v=1&name=Home%20Mac%20mini&token=${TOKEN}&url=https%3A%2F%2Fmac.tail.ts.net&direct=192.168.0.20%3A8766`));
    expect(parsed).toEqual({ name: "Home Mac mini", token: TOKEN, url: "https://mac.tail.ts.net/", directAddress: "192.168.0.20:8766", tailscaleOnly: false });
  });

  it("rejects damaged, duplicated or unsupported links", () => {
    expect(() => parsePairingLink("https://example.com")).toThrow(PairingError);
    expect(() => parsePairingLink(link(`v=1&token=${TOKEN}&token=${TOKEN}&direct=a:1`))).toThrow(/damaged/);
    expect(() => parsePairingLink(link(`v=2&token=${TOKEN}&direct=a:1`))).toThrow(/Update Cantrip Gateway/);
    expect(() => parsePairingLink(link(`v=1&token=short&direct=a:1`))).toThrow(/token is invalid/);
    expect(() => parsePairingLink(link(`v=1&token=${TOKEN}&tailscaleOnly=1&direct=a:1`))).toThrow(/https:\/\/ URL/);
    expect(() => parsePairingLink(link(`v=1&token=${TOKEN}`))).toThrow(/direct address/);
  });

  it("strips control and bidi characters from the host's label", () => {
    expect(parsePairingLink(link(`v=1&name=%E2%80%AEevil%0Aname&token=${TOKEN}&direct=a.local:8766`)).name).toBe("evil name");
  });
});

describe("addresses", () => {
  it("normalizes URLs and allows plain HTTP only for this computer", () => {
    expect(normalizeURL("mac.tail.ts.net")).toBe("https://mac.tail.ts.net/");
    expect(normalizeURL("http://127.0.0.1:8765")).toBe("http://127.0.0.1:8765/");
    expect(() => normalizeURL("http://192.168.0.20:8765")).toThrow(/https/);
    expect(() => normalizeURL("https://user:pw@mac.example")).toThrow();
  });

  it("validates direct addresses", () => {
    expect(normalizeDirectAddress("Home-Mac.local:8766")).toBe("home-mac.local:8766");
    expect(normalizeDirectAddress("[FD7A::1]:8766")).toBe("[fd7a::1]:8766");
    for (const bad of ["192.168.0.20", "host:0", "host:70000", "-bad:1", "a b:1"]) {
      expect(() => normalizeDirectAddress(bad)).toThrow(/host:port/);
    }
  });

  it("names a server like the Mac apps do", () => {
    expect(displayName(validateServer({ name: "", url: "https://mac.tail.ts.net", directAddress: "", tailscaleOnly: false }))).toBe("mac.tail.ts.net");
    expect(displayName(validateServer({ name: "", url: "", directAddress: "10.0.0.2:8766", tailscaleOnly: false }))).toBe("10.0.0.2:8766");
  });
});

describe("SettingsStore", () => {
  const folders: string[] = [];
  afterEach(() => folders.splice(0).forEach((folder) => rmSync(folder, { recursive: true, force: true })));
  const box = (available = true): SecretBox => ({
    isEncryptionAvailable: () => available,
    encryptString: (text) => Buffer.from(`enc:${Buffer.from(text).toString("base64")}`),
    decryptString: (data) => {
      const text = data.toString();
      if (!text.startsWith("enc:")) throw new Error("bad");
      return Buffer.from(text.slice(4), "base64").toString();
    },
  });
  const server = { name: "Mac mini", url: "", directAddress: "192.168.0.20:8766", tailscaleOnly: false };

  it("saves the token only in encrypted form and loads it back", () => {
    const folder = mkdtempSync(join(tmpdir(), "gateway-store-"));
    folders.push(folder);
    const file = join(folder, "settings.json");
    new SettingsStore(file, box()).save(server, TOKEN);
    expect(readFileSync(file, "utf8")).not.toContain(TOKEN);
    expect(new SettingsStore(file, box()).load()).toEqual({ server, token: TOKEN });
  });

  it("refuses to save without OS encryption and forgets undecryptable tokens", () => {
    const folder = mkdtempSync(join(tmpdir(), "gateway-store-"));
    folders.push(folder);
    const file = join(folder, "settings.json");
    expect(() => new SettingsStore(file, box(false)).save(server, TOKEN)).toThrow(/encrypt/);
    new SettingsStore(file, box()).save(server, TOKEN);
    const other: SecretBox = { ...box(), decryptString: () => { throw new Error("other user"); } };
    expect(new SettingsStore(file, other).load()).toBeNull();
  });
});
