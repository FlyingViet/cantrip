import { beforeEach, describe, expect, it, vi } from "vitest";

// The transcript modules touch the page and the preload bridge when they load.
vi.hoisted(() => {
  const noop = () => {};
  const scope = globalThis as Record<string, unknown>;
  const stored = new Map<string, string>();
  Object.defineProperty(scope, "localStorage", {
    configurable: true,
    value: { getItem: (key: string) => stored.get(key) ?? null, setItem: (key: string, value: string) => void stored.set(key, value), removeItem: (key: string) => void stored.delete(key) },
  });
  scope.document = { addEventListener: noop, removeEventListener: noop, visibilityState: "visible" };
  scope.window = scope;
  scope.addEventListener = noop;
  scope.removeEventListener = noop;
});
vi.mock("../src/gateway/bridge", () => ({
  bridge: {
    key: "gateway-key", version: "test", platform: "win32", server: "", focused: true,
    status: { connected: true, route: "", message: "", server: "" },
    openSettings() {}, openExternal() {}, showLog() {}, onStatus() {}, onCommand() {}, onActive() {},
  },
  isWindows: true,
  primaryKeyLabel: "Ctrl+",
  shortcut: (keys: string) => keys,
}));

import type { RemoteMessage, RemoteSessionSummary } from "../src/gateway/api/types";
import { tabRowDetail } from "../src/gateway/state/format";
import * as nav from "../src/gateway/state/nav";
import * as remote from "../src/gateway/state/remote";
import {
  addMention, encodeMentions, insertMention, matchMentions, mentionAccessibilityLabel, mentionCandidates, mentionCountAnnouncement,
  mentionDetail, mentionLabel, mentionListState, mentionProject, mentionQuery, mentionSafeCut, mentionSegments, mentionToken,
  moveMentionHighlight, noMentionMatchText, normalizeMention, parseMentions, plainMentions, remainingMentions, removeMentionText,
  supportsMentions, type MentionCandidate,
} from "../src/gateway/state/tabMentions";
import { tagLabel } from "../src/gateway/state/threads";
import { queuedText } from "../src/gateway/ui/activity/activityLogic";
import { Markdown } from "../src/gateway/ui/transcript/Markdown";
import { MessageRow } from "../src/gateway/ui/transcript/Message";
import { MentionChips } from "../src/gateway/ui/transcript/TabMentions";

// MARK: A small VNode walker (no DOM): components are called with their props, like a shallow render.

interface VNode { type: unknown; props: Record<string, unknown> & { children?: unknown } }
interface Element { tag: string; props: Record<string, unknown>; children: Node[] }
type Node = Element | string;

function isVNode(value: unknown): value is VNode {
  return typeof value === "object" && value !== null && "type" in value && "props" in value;
}

function render(value: unknown): Node[] {
  if (value == null || typeof value === "boolean") return [];
  if (Array.isArray(value)) return value.flatMap(render);
  if (typeof value === "string" || typeof value === "number") return [String(value)];
  if (!isVNode(value)) return [];
  if (typeof value.type === "function") return render((value.type as (props: unknown) => unknown)(value.props));
  const { children, ...props } = value.props;
  return [{ tag: String(value.type), props, children: render(children) }];
}

function text(nodes: Node[]): string {
  return nodes.map((node) => (typeof node === "string" ? node : text(node.children))).join("");
}

function elements(nodes: Node[]): Element[] {
  return nodes.flatMap((node) => (typeof node === "string" ? [] : [node, ...elements(node.children)]));
}

function byClass(nodes: Node[], name: string): Element[] {
  return elements(nodes).filter((node) => String(node.props.class ?? "").split(" ").includes(name));
}

// MARK: Fixtures

const TV = "8F3A2C10-1234-4ABC-9DEF-0123456789AB";
const TV_REMOTE = "1B2C3D4E-5F60-4718-89AB-CDEF01234567";
const SONY = "5A0E7B1C-2D3E-4F50-8A61-72B3C4D5E6F7";
const HOME = "00000000-0000-4000-8000-00000000C0DE";

function tab(id: string, title: string, overrides: Partial<RemoteSessionSummary> = {}): RemoteSessionSummary {
  return {
    id, title, customTitle: "", workdir: `/Users/alex/Projects/${title.replace(/\s+/g, "-")}`, isStreaming: false, pendingInputCount: 0,
    mentionable: true, supportsTabMentions: true, ...overrides,
  } as RemoteSessionSummary;
}

function candidate(title: string, overrides: Partial<MentionCandidate> = {}): MentionCandidate {
  return { id: TV, title, workdir: "", parentTitle: null, isStreaming: false, needsAnswer: false, isChild: false, ...overrides };
}

beforeEach(() => {
  remote.sessions.value = [];
});

// MARK: Tokens

describe("tokens", () => {
  it("parses tokens with upper- or lowercase IDs", () => {
    const text = `ask @[Sony TV](cantrip-tab:${SONY}) and @[Bass](cantrip-tab:${TV.toLowerCase()})`;
    expect(parseMentions(text)).toEqual([
      { label: "Sony TV", id: SONY, start: 4, end: 4 + `@[Sony TV](cantrip-tab:${SONY})`.length },
      { label: "Bass", id: TV, start: text.indexOf("@[Bass"), end: text.length },
    ]);
    expect(parseMentions("@[x](cantrip-tab:not-a-uuid) @[](cantrip-tab:" + TV + ")")).toEqual([]);
  });

  it("reads tokens as @Label", () => {
    expect(plainMentions(`Hey @[Sony TV](cantrip-tab:${SONY}), check (@[TV](cantrip-tab:${TV})).`)).toBe("Hey @Sony TV, check (@TV).");
    expect(plainMentions("no tokens [here](https://x.y)")).toBe("no tokens [here](https://x.y)");
    expect(plainMentions(undefined)).toBeUndefined();
  });

  it("splits text into runs and mentions", () => {
    expect(mentionSegments(`a @[TV](cantrip-tab:${TV}) b`)).toEqual([
      { kind: "text", text: "a " }, { kind: "mention", label: "TV", id: TV }, { kind: "text", text: " b" },
    ]);
    expect(mentionSegments("")).toEqual([{ kind: "text", text: "" }]);
  });

  it("never cuts a token in half", () => {
    const token = `@[TV](cantrip-tab:${TV})`;
    const value = `abc ${token} def`;
    expect(mentionSafeCut(value, 10)).toBe(4);
    expect(mentionSafeCut(value, 4)).toBe(4);
    expect(mentionSafeCut(value, 4 + token.length + 1)).toBe(4 + token.length + 1);
  });

  it("sanitizes labels: one line, no brackets, 60 characters, never empty", () => {
    expect(mentionLabel("  Fix [the] build\n\tnow  ")).toBe("Fix the build now");
    expect(mentionLabel("[]")).toBe("tab");
    expect(mentionLabel("   ")).toBe("tab");
    expect(mentionLabel("a".repeat(70))).toBe("a".repeat(60));
    expect(mentionLabel(`${"b".repeat(59)} c`)).toBe("b".repeat(59));
    // Characters, not UTF-16 units: a family emoji counts once.
    expect(mentionLabel("👩‍👩‍👧".repeat(61))).toBe("👩‍👩‍👧".repeat(60));
    expect(mentionToken("Sony [TV]", SONY.toLowerCase())).toBe(`@[Sony TV](cantrip-tab:${SONY})`);
  });
});

// MARK: Composer

describe("mention query", () => {
  it("starts at an @ that begins a word", () => {
    expect(mentionQuery("@")).toEqual({ at: 0, query: "" });
    expect(mentionQuery("hey @so")).toEqual({ at: 4, query: "so" });
    expect(mentionQuery("(@tv")).toEqual({ at: 1, query: "tv" });
    expect(mentionQuery("say “@tv")).toEqual({ at: 5, query: "tv" });
    expect(mentionQuery("line\n@ba")).toEqual({ at: 5, query: "ba" });
    expect(mentionQuery("@Sony TV")).toEqual({ at: 0, query: "Sony TV" });
  });

  it("never triggers inside a word (emails, handles)", () => {
    expect(mentionQuery("a@b.com")).toBeNull();
    expect(mentionQuery("mail alex@example")).toBeNull();
    expect(mentionQuery("x@handle")).toBeNull();
  });

  it("stops at newlines, leading spaces, tokens and 48 characters", () => {
    expect(mentionQuery("@ba\nx")).toBeNull();
    expect(mentionQuery("@ sony")).toBeNull();
    expect(mentionQuery(`@[TV](cantrip-tab:${TV}`)).toBeNull();
    expect(mentionQuery(`@${"a".repeat(48)}`)).toEqual({ at: 0, query: "a".repeat(48) });
    expect(mentionQuery(`@${"a".repeat(49)}`)).toBeNull();
  });

  it("follows the caret", () => {
    expect(mentionQuery("ask @so about it", 7)).toEqual({ at: 4, query: "so" });
    expect(mentionQuery("ask @so about it", 3)).toBeNull();
    expect(mentionQuery("@a @b", 2)).toEqual({ at: 0, query: "a" });
    expect(mentionQuery("abc", 9)).toBeNull();
    // The caret before a leading "@" (Home key after a pick) is not in a mention.
    expect(mentionQuery("@Sony TV fix", 0)).toBeNull();
    expect(mentionQuery("@", 1)).toEqual({ at: 0, query: "" });
  });
});

describe("matching", () => {
  const tabs = [
    candidate("Cantrip", { workdir: "/Users/alex/Coding/Cantrip" }),
    candidate("Bass Compass", { workdir: "/Users/alex/Projects/bass" }),
    candidate("Sony TV", { workdir: "/Users/alex/Projects/sony" }),
    candidate("Café notes", { workdir: "/Users/alex" }),
    candidate("Scratch", { workdir: "/Users/alex/Projects/tv-remote" }),
    candidate("Abba road"),
  ];
  const titles = (query: string) => matchMentions(query, tabs).map((item) => item.title);

  it("lists every tab in order for an empty query, at most 8", () => {
    expect(titles("")).toEqual(tabs.map((item) => item.title));
    expect(matchMentions("", Array.from({ length: 12 }, (_, index) => candidate(`Tab ${index}`)))).toHaveLength(8);
  });

  it("ranks title prefix, then word prefixes, then contains, then project", () => {
    expect(titles("ba")).toEqual(["Bass Compass", "Abba road"]);
    expect(titles("comp")).toEqual(["Bass Compass"]);
    expect(titles("co ba")).toEqual(["Bass Compass"]);
    expect(titles("tv")).toEqual(["Sony TV", "Scratch"]);
    expect(titles("zz")).toEqual([]);
  });

  it("ignores case and diacritics", () => {
    expect(titles("CAFE")).toEqual(["Café notes"]);
    expect(normalizeMention("  Ça   Va\t")).toBe("ca va");
    expect(matchMentions("son", [candidate("Sôn Tùng")]).map((item) => item.title)).toEqual(["Sôn Tùng"]);
  });

  it("shows rows, one info row, or nothing", () => {
    expect(mentionListState("ba", ["x"], 3)).toBe("rows");
    expect(mentionListState("zz", [], 3)).toBe("empty");
    expect(mentionListState("zz top", [], 3)).toBe("hidden");
    expect(mentionListState("", [], 0)).toBe("hidden");
    expect(noMentionMatchText("zz")).toBe("No open tab matches “zz”");
    expect(mentionCountAnnouncement(1)).toBe("1 tab");
    expect(mentionCountAnnouncement(3)).toBe("3 tabs");
    expect(moveMentionHighlight(3, 2, 1)).toBe(0);
    expect(moveMentionHighlight(3, 0, -1)).toBe(2);
    expect(moveMentionHighlight(0, 0, 1)).toBe(-1);
  });
});

describe("rows", () => {
  it("say whose child it is, the project and whether it's busy", () => {
    const child = candidate("Mention chips", { parentTitle: "Cantrip", workdir: "/Users/alex/Coding/Cantrip", isStreaming: true, isChild: true });
    expect(mentionDetail(child)).toBe("Child of Cantrip · Cantrip · Working");
    expect(mentionAccessibilityLabel(child)).toBe("Mention chips, child of Cantrip, project Cantrip, working");
    expect(mentionDetail(candidate("cantrip", { workdir: "/Users/alex/Coding/Cantrip", needsAnswer: true, isStreaming: true }))).toBe("Needs your answer");
    expect(mentionDetail(candidate("Notes", { workdir: "/Users/alex/" }))).toBe("");
  });

  it("omit the home folder as a project", () => {
    expect(mentionProject("/Users/alex")).toBeNull();
    expect(mentionProject("/Users/alex/")).toBeNull();
    expect(mentionProject("/")).toBeNull();
    expect(mentionProject("")).toBeNull();
    expect(mentionProject("/Users/alex/Coding/Bass-Compass/")).toBe("Bass-Compass");
  });
});

describe("candidates", () => {
  it("offers mentionable tabs only, never the tab being written in", () => {
    const sessions = [
      tab(TV, "TV"),
      tab(SONY, "Sony TV", { customTitle: "Living room" }),
      tab(TV_REMOTE, "TV Remote", { parentID: TV, child: { state: "working", title: "TV Remote", parentTitle: "Old TV", statusLine: "Working" } }),
      tab("A0000000-0000-4000-8000-000000000001", "Private Local", { mentionable: false }),
      tab("A0000000-0000-4000-8000-000000000002", "Old host", { mentionable: undefined }),
    ];
    expect(mentionCandidates(sessions, TV).map((item) => item.title)).toEqual(["Living room", "TV Remote"]);
    const child = mentionCandidates(sessions, HOME).find((item) => item.id === TV_REMOTE)!;
    expect(child).toMatchObject({ parentTitle: "TV", isChild: true });
    expect(mentionCandidates([sessions[2]], HOME)[0].parentTitle).toBe("Old TV");
  });

  it("needs supportsTabMentions on the composing session", () => {
    expect(supportsMentions({ supportsTabMentions: true })).toBe(true);
    expect(supportsMentions({ supportsTabMentions: false })).toBe(false);
    expect(supportsMentions({})).toBe(false);
    expect(supportsMentions(null)).toBe(false);
  });
});

describe("picking", () => {
  it("replaces the query with @Label and a space, caret after it", () => {
    expect(insertMention("Sony TV", 4, 7, "ask @so")).toEqual({ text: "ask @Sony TV ", label: "Sony TV", caret: 13 });
    expect(insertMention("Sony TV", 4, 7, "ask @so about it")).toEqual({ text: "ask @Sony TV about it", label: "Sony TV", caret: 13 });
    expect(insertMention("Sony TV", 4, 7, "ask @soabout")).toEqual({ text: "ask @Sony TV about", label: "Sony TV", caret: 13 });
    expect(insertMention("[x]", 0, 1, "@")).toEqual({ text: "@x ", label: "x", caret: 3 });
  });

  it("keeps one pick per label", () => {
    expect(addMention([{ id: TV, label: "TV" }, { id: SONY, label: "Sony TV" }], { id: TV_REMOTE, label: "TV" }))
      .toEqual([{ id: SONY, label: "Sony TV" }, { id: TV_REMOTE, label: "TV" }]);
  });
});

describe("sending", () => {
  const tv = { id: TV, label: "TV" };
  const tvRemote = { id: TV_REMOTE, label: "TV Remote" };

  it("encodes picked labels that start a word and end at a boundary", () => {
    expect(encodeMentions("ask @TV now", [tv])).toBe(`ask @[TV](cantrip-tab:${TV}) now`);
    expect(encodeMentions("(@TV), @TV. @TV", [tv])).toBe(`(@[TV](cantrip-tab:${TV})), @[TV](cantrip-tab:${TV}). @[TV](cantrip-tab:${TV})`);
    expect(encodeMentions("@TVs and a@TV and @TV_x and @TVé", [tv])).toBe("@TVs and a@TV and @TV_x and @TVé");
    expect(encodeMentions("hand-typed @Sony TV stays", [])).toBe("hand-typed @Sony TV stays");
  });

  it("matches @TV Remote before @TV, whatever the pick order", () => {
    const expected = `@[TV Remote](cantrip-tab:${TV_REMOTE}) and @[TV](cantrip-tab:${TV})`;
    expect(encodeMentions("@TV Remote and @TV", [tv, tvRemote])).toBe(expected);
    expect(encodeMentions("@TV Remote and @TV", [tvRemote, tv])).toBe(expected);
  });

  it("checks every pick together: @TV is gone when only @TV Remote is left", () => {
    expect(remainingMentions([tv, tvRemote], "@TV Remote and @TV")).toEqual([tv, tvRemote]);
    expect(remainingMentions([tv, tvRemote], "ask @TV Remote")).toEqual([tvRemote]);
    expect(remainingMentions([tv, tvRemote], "ask @TV")).toEqual([tv]);
    expect(remainingMentions([tv, tvRemote], "ask @TVs")).toEqual([]);
  });

  it("removes one pick's text and leaves the others as typed", () => {
    expect(removeMentionText("ask @TV Remote and @TV now", tv, [tv, tvRemote])).toBe("ask @TV Remote and now");
    expect(removeMentionText("ask @TV Remote and @TV now", tvRemote, [tv, tvRemote])).toBe("ask and @TV now");
    expect(removeMentionText("ask @TV Remote", tv, [tvRemote])).toBe("ask @TV Remote");
    expect(removeMentionText("@TV", tv, [tv])).toBe("");
  });
});

// MARK: Rendering

describe("rendering", () => {
  const token = `@[Sony TV](cantrip-tab:${SONY})`;

  it("shows tokens as @Label in plain-text places", () => {
    expect(queuedText({ text: `ask ${token}` })).toBe("ask @Sony TV");
    expect(tagLabel({ id: "T", prompt: `about ${token}` })).toBe("Reply to: about @Sony TV");
    expect(tabRowDetail(tab(TV, "TV", { preview: `Checked ${token}` }))?.text).toBe("Checked @Sony TV");
  });

  it("draws mentions in user bubbles, never the raw token", () => {
    const message: RemoteMessage = { id: "U1", role: "user", text: `please ask ${token} first`, thinking: "", activities: [], isLocalPrivate: false };
    const nodes = render(MessageRow({ message, session: tab(HOME, "Cantrip Home"), lane: "home", streaming: false, reported: new Set() }));
    expect(text(nodes)).toBe("please ask @Sony TV first");
    const mention = byClass(nodes, "mention");
    expect(mention).toHaveLength(1);
    expect(mention[0].tag).toBe("span");
  });

  it("draws mentions in Markdown replies; an open tab's mention opens it", () => {
    remote.sessions.value = [tab(SONY, "Sony TV")];
    const nodes = render(Markdown({ text: `**Asked ${token}.** Then \`${token}\`` }));
    expect(text(nodes)).toBe("Asked @Sony TV. Then @Sony TV");
    const [mention] = byClass(nodes, "mention");
    expect(mention.tag).toBe("button");
    expect(mention.props["aria-label"]).toBe("@Sony TV, mentioned tab. Opens it");
    (mention.props.onClick as () => void)();
    expect(nav.openTabID.value).toBe(SONY);
  });

  it("chips name their remove buttons", () => {
    const nodes = render(MentionChips({ mentions: [{ id: SONY, label: "Sony TV" }], disabled: false, onRemove: () => {} }));
    expect(text(nodes)).toBe("@Sony TV");
    expect(elements(nodes).find((node) => node.tag === "button")?.props["aria-label"]).toBe("Remove mention Sony TV");
  });
});
