import { beforeEach, describe, expect, it, vi } from "vitest";

const calls: { id: string; action: string; body: unknown }[] = [];
let answer = true;
const confirms: string[] = [];
vi.mock("../src/gateway/state/remote", () => ({
  isMutating: { value: false },
  museRequestAction: async (id: string, action: string, body: unknown) => { calls.push({ id, action, body }); },
}));
vi.mock("../src/gateway/ui/kit", () => ({
  confirmDialog: async (options: { title: string; message?: string }) => { confirms.push(`${options.title} ${options.message ?? ""}`); return answer; },
  toast: () => {},
}));

import type { RemoteMuseRequest } from "../src/gateway/api/types";
import { museRequestAct } from "../src/gateway/ui/transcript/MuseRequest";

// Fake IDs and text only.
const OPEN: RemoteMuseRequest = {
  id: "5B0C7E2F-4A86-4E7F-9A1B-3F6B2A108C4D", title: "Growth plan", text: "Exact text for Muse.", state: "waiting",
  actions: ["send", "edit", "cancel"], sendLabel: "Send",
};

describe("Home's Muse request card", () => {
  beforeEach(() => { calls.length = 0; confirms.length = 0; answer = true; });

  it("sends exactly the text it shows, without asking again", async () => {
    expect(await museRequestAct(OPEN, "send", OPEN.text)).toBe(true);
    expect(calls).toEqual([{ id: OPEN.id, action: "send", body: { text: "Exact text for Muse." } }]);
    expect(confirms).toEqual([]);
  });

  it("asks before Send anyway on a held request, and sends nothing when declined", async () => {
    const held = { ...OPEN, state: "held", sendLabel: "Send anyway", findings: ["mail content"] };
    answer = false;
    expect(await museRequestAct(held, "send", held.text)).toBe(false);
    expect(calls).toEqual([]);
    expect(confirms[0]).toContain("mail content");
    answer = true;
    expect(await museRequestAct(held, "send", held.text)).toBe(true);
    expect(calls).toEqual([{ id: OPEN.id, action: "send", body: { text: held.text, override: true } }]);
  });

  it("sends an edited held text without override, so the Mac checks it again", async () => {
    const held = { ...OPEN, state: "held", findings: ["mail content"] };
    await museRequestAct(held, "send", "A clean rewrite.");
    expect(confirms).toEqual([]);
    expect(calls[0].body).toEqual({ text: "A clean rewrite." });
  });

  it("edits and cancels with nothing else in the body", async () => {
    await museRequestAct(OPEN, "edit", "Shorter, please.");
    await museRequestAct(OPEN, "cancel");
    expect(calls).toEqual([
      { id: OPEN.id, action: "edit", body: { text: "Shorter, please." } },
      { id: OPEN.id, action: "cancel", body: {} },
    ]);
  });
});
