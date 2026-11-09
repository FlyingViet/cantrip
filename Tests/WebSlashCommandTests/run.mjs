// Browser Remote slash-command suggestions: runs the web client's own matching, choosing and
// caching functions, read from the webAppTemplate Swift string literal.
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import vm from "node:vm";

const root = fileURLToPath(new URL("../..", import.meta.url));
const swift = readFileSync(`${root}Sources/Cantrip/RemoteControlServer.swift`, "utf8");
let failures = 0, passes = 0;
function expect(condition, message) {
    if (condition) passes++;
    else { failures++; console.log(`FAIL: ${message}`); }
}
function same(actual, expected, message) {
    const a = JSON.stringify(actual), e = JSON.stringify(expected);
    expect(a === e, `${message}\n  expected ${e}\n  actual   ${a}`);
}

// The page source is a Swift multi-line literal: undo its escapes so the code runs as browsers see it.
function swiftUnescape(text) {
    return text.replace(/\\(u\{[0-9a-fA-F]+\}|\n|.)/g, (match, escape) => {
        if (escape.startsWith("u{")) return String.fromCodePoint(parseInt(escape.slice(2, -1), 16));
        const simple = { "\\": "\\", '"': '"', "'": "'", n: "\n", t: "\t", r: "\r", 0: "\0", "\n": "" }[escape];
        if (simple === undefined) throw new Error(`Unsupported Swift escape ${match} (interpolation in the web template?)`);
        return simple;
    });
}
function templateSlice(startMarker, endMarker) {
    const template = swift.slice(swift.indexOf('static let webAppTemplate = """'));
    const start = template.indexOf(startMarker);
    const end = template.indexOf(endMarker, start + 1);
    if (start < 0 || end < 0) throw new Error(`Missing ${startMarker} .. ${endMarker} in webAppTemplate`);
    return swiftUnescape(template.slice(start, end));
}

// The whole page script must parse: one bad escape (a "\n" that Swift turns into a real newline)
// stops every function in the browser Remote from being defined.
{
    const template = swift.slice(swift.indexOf('static let webAppTemplate = """') + 'static let webAppTemplate = """'.length);
    const html = swiftUnescape(template.slice(0, template.indexOf('\n    """')));
    const scripts = [...html.matchAll(/<script[^>]*>([\s\S]*?)<\/script>/g)].map(match => match[1]);
    expect(scripts.length > 0, "the page has a script");
    for (const script of scripts) {
        try { new vm.Script(script); passes++; }
        catch (error) { failures++; console.log(`FAIL: the page script doesn't parse: ${error.message}`); }
    }
}

const pure = vm.createContext({});
vm.runInContext(templateSlice("    function slashToken(", "    const slashCache="), pure);
const { slashToken, matchCommands, chooseCommand, commandTitle, slashCommandsStale } = pure;

// Generic fixture from the slash-command contract.
const fixture = {
    backend: "Copilot", workdir: "/tmp/project", revision: "r1", status: null, commands: [
        { name: "plan", description: "Create an implementation plan before coding", kind: "builtin", source: "Copilot", inputHint: "prompt", requiresInput: false, aliases: [], insert: "/plan ", availability: "runs", note: null, action: null },
        { name: "usage", description: "Display session usage metrics and statistics", kind: "builtin", source: "Copilot", inputHint: null, requiresInput: false, aliases: [], insert: "/usage ", availability: "runs", note: null, action: null },
        { name: "model", description: "Select the AI model for this session", kind: "builtin", source: "Copilot", inputHint: "model", requiresInput: false, aliases: [], insert: "/model ", availability: "cantrip", note: "Opens this tab's model settings.", action: "modelSettings" },
        { name: "allow-all", description: "Enable all permissions", kind: "builtin", source: "Copilot", inputHint: "[on|off|show]", requiresInput: false, aliases: ["yolo"], insert: "/allow-all ", availability: "unavailable", note: "Cantrip's approval settings decide what Copilot may do in this tab.", action: null },
        { name: "fixture-skill", description: "Fixture project skill for tests", kind: "skill", source: "Project", inputHint: "instructions for the skill", requiresInput: false, aliases: [], insert: "/fixture-skill ", availability: "runs", note: null, action: null },
        { name: "review-helper", description: "Review the current diff", kind: "custom", source: "Personal", inputHint: null, requiresInput: false, aliases: [], insert: "/review-helper ", availability: "runs", note: null, action: null },
    ],
};
const byName = Object.fromEntries(fixture.commands.map(command => [command.name, command]));
function suggest(text) {
    const query = slashToken(text);
    if (query === null) return null;
    const { rows, highlighted } = matchCommands(fixture.commands, query);
    return { rows: rows.map(row => [row.command.name, row.score]), highlighted };
}

// When the list shows.
same(slashToken("/"), "", "a lone slash opens the full list");
same(slashToken("/PL"), "pl", "the token is lowercased");
same(slashToken("/tmp/x"), null, "path text never suggests");
same(slashToken("/Users/someone/project"), null, "absolute paths never suggest");
same(slashToken("/plan x"), null, "a space closes the list while the argument is typed");
same(slashToken("/plan "), null, "a trailing space closes the list");
same(slashToken(" /plan"), null, "leading whitespace never suggests");
same(slashToken("/plan\nmore"), null, "multiline text never suggests");
same(slashToken("/plan\t"), null, "tabs count as whitespace");
same(slashToken("plan"), null, "text without a leading slash never suggests");
same(slashToken(""), null, "an empty composer never suggests");

// Expected filter results with the fixture.
same(suggest("/"), { rows: [["plan", 1], ["usage", 1], ["model", 1], ["fixture-skill", 1], ["review-helper", 1], ["allow-all", 1]], highlighted: -1 },
    "/ lists every command in host order, unavailable last, nothing highlighted");
same(suggest("/u"), { rows: [["usage", 1], ["fixture-skill", 3]], highlighted: 0 }, "/u highlights usage; fixture-skill contains u");
same(suggest("/pl"), { rows: [["plan", 1]], highlighted: 0 }, "/pl highlights plan only");
same(suggest("/re"), { rows: [["review-helper", 1], ["fixture-skill", 3]], highlighted: 0 }, "/re highlights review-helper; fixture contains re");
same(suggest("/yo"), { rows: [["allow-all", 2]], highlighted: -1 }, "/yo matches the alias but never highlights an unavailable row");
same(suggest("/tmp/x"), null, "/tmp/x shows no list");
same(suggest("/plan x"), null, "/plan x shows no list");
same(suggest(" /plan"), null, " /plan shows no list");

// Score rules.
same(suggest("/usage"), { rows: [["usage", 0]], highlighted: 0 }, "an exact name scores 0");
same(suggest("/USAGE"), { rows: [["usage", 0]], highlighted: 0 }, "matching ignores case");
same(suggest("/se"), { rows: [["usage", 4], ["model", 4]], highlighted: -1 }, "description words match from two characters, unhighlighted");
same(suggest("/c"), { rows: [], highlighted: -1 }, "a one-character token never matches descriptions");
same(suggest("/fixtureskill"), { rows: [["fixture-skill", 3]], highlighted: -1 }, "separators are ignored when matching inside names");
same(suggest("/allow_all"), { rows: [["allow-all", 3]], highlighted: -1 }, "separator-insensitive matches stay unhighlighted when unavailable");
same(suggest("/zzz"), { rows: [], highlighted: -1 }, "no match closes the list");
const many = Array.from({ length: 60 }, (_, index) => ({ name: `cmd${index}`, description: "", insert: `/cmd${index} `, availability: "runs" }));
same(matchCommands(many, "").rows.length, 50, "at most 50 rows are shown");
same(matchCommands(many, "cmd5").rows.map(row => row.command.name), ["cmd5", "cmd50", "cmd51", "cmd52", "cmd53", "cmd54", "cmd55", "cmd56", "cmd57", "cmd58", "cmd59"],
    "equal scores keep the host order after the exact match");
const shadowed = [{ name: "beta", description: "", availability: "unavailable" }, { name: "betamax", description: "", availability: "runs" }];
same(matchCommands(shadowed, "beta").rows.map(row => row.command.name), ["betamax", "beta"], "unavailable rows sort after available ones regardless of score");
same(matchCommands(shadowed, "beta").highlighted, 0, "the available prefix match is highlighted ahead of an exact unavailable match");

// Choosing a row.
same(chooseCommand(byName["usage"], "return", true), { kind: "send", text: "/usage ", send: "/usage" }, "Return sends an argument-free command, trimmed");
same(chooseCommand(byName["usage"], "tab", true), { kind: "insert", text: "/usage " }, "Tab inserts without sending");
same(chooseCommand(byName["review-helper"], "return", false), { kind: "send", text: "/review-helper ", send: "/review-helper" }, "a custom command without input runs on Return");
same(chooseCommand(byName["plan"], "return", true), { kind: "insert", text: "/plan " }, "an input hint keeps focus for the argument");
same(chooseCommand(byName["fixture-skill"], "return", true), { kind: "insert", text: "/fixture-skill " }, "skills with hints insert");
same(chooseCommand({ ...byName["usage"], requiresInput: true }, "return", true), { kind: "insert", text: "/usage " }, "requiresInput inserts even without a hint");
same(chooseCommand({ ...byName["usage"], inputHint: "  " }, "return", true), { kind: "send", text: "/usage ", send: "/usage" }, "a blank hint counts as no hint");
same(chooseCommand(byName["allow-all"], "return", true), { kind: "none" }, "unavailable rows are not choosable with Return");
same(chooseCommand(byName["allow-all"], "tab", true), { kind: "none" }, "unavailable rows are not choosable with Tab");
same(chooseCommand(byName["model"], "return", true), { kind: "modelSettings", text: "" }, "modelSettings clears the token and opens settings");
same(chooseCommand(byName["model"], "tab", true), { kind: "modelSettings", text: "" }, "Tab also opens model settings");
same(chooseCommand(byName["model"], "return", false), { kind: "insert", text: "/model " }, "without model settings the row just inserts");
same(chooseCommand({ ...byName["plan"], action: "somethingNew" }, "return", true), { kind: "insert", text: "/plan " }, "unknown actions just insert");
const codex = { name: "imagegen", description: "Generate images", kind: "skill", source: "System", inputHint: null, requiresInput: false, aliases: [], insert: "$imagegen ", availability: "runs", note: null, action: null };
same(chooseCommand(codex, "tab", false), { kind: "insert", text: "$imagegen " }, "Codex skills insert their $mention exactly");
same(chooseCommand(codex, "return", false), { kind: "send", text: "$imagegen ", send: "$imagegen" }, "Codex skills send the host's insert text, never a built one");
same(chooseCommand({ ...codex, inputHint: "prompt" }, "return", false), { kind: "insert", text: "$imagegen " }, "Codex skills with a hint keep focus");
same(chooseCommand({ ...codex, insert: "" }, "return", false), { kind: "none" }, "a row without insert text is never built by the client");
same(slashToken("$imagegen "), null, "an inserted $skill closes the list");
same(matchCommands([codex], "image").rows.map(row => [row.command.name, row.score]), [["imagegen", 1]], "Codex skills match by name");

// Row titles show the first token of the insert text.
same(commandTitle(codex), "$imagegen", "a Codex skill row is titled with its $mention");
same(commandTitle(byName["plan"]), "/plan", "a slash command row is titled with its slash name");
same(commandTitle({ name: "fixture", insert: "/fixture-run now " }), "/fixture-run", "the title is the insert's first token, not the name");

// Cache freshness.
const session = { id: "a", workdir: "/tmp/project", modelSettingsRevision: 3 };
const entry = { data: { commands: [] }, at: 1_000, workdir: "/tmp/project", modelRevision: 3 };
expect(slashCommandsStale(undefined, session, 1_000), "a missing cache entry is fetched");
expect(slashCommandsStale({ ...entry, data: null }, session, 1_000), "a failed or pending first fetch is retried on the next slash entry");
expect(!slashCommandsStale(entry, session, 30_999), "a fresh entry is reused");
expect(slashCommandsStale(entry, session, 31_000), "entries older than 30 s are refetched");
expect(slashCommandsStale(entry, { ...session, workdir: "/tmp/other" }, 2_000), "a new workdir refetches");
expect(slashCommandsStale(entry, { ...session, modelSettingsRevision: 4 }, 2_000), "a backend or model change refetches");

// Fetching: one request per tab; responses are kept only for their tab, pairing and sequence.
const pending = [], synced = [];
const fetching = vm.createContext({
    sessionItems: [{ id: "a", supportsBackendCommands: true, workdir: "/w", modelSettingsRevision: 1 },
        { id: "b", supportsBackendCommands: true, workdir: "/w", modelSettingsRevision: 1 },
        { id: "old", workdir: "/w", modelSettingsRevision: 1 }],
    selected: "a", token: "t1",
    api: path => new Promise((resolve, reject) => pending.push({ path, resolve, reject })),
    syncSlashCommands: () => synced.push("sync"),
});
vm.runInContext(`${templateSlice("    function slashToken(", "    function slashOption(")}
    var cache = slashCache, load = id => loadSlashCommands(sessionItems.find(s => s.id === id));`, fetching);
const settle = () => new Promise(resolve => setImmediate(resolve));
fetching.load("old");
same(pending.length, 0, "older hosts without supportsBackendCommands are never asked");
fetching.load("a"); fetching.load("a");
same(pending.map(request => request.path), ["/api/v1/sessions/a/commands"], "one request per tab while it is pending");
pending.shift().resolve({ ...fixture });
await settle();
same(fetching.cache.get("a").data.commands.length, 6, "the response is cached for its tab");
same(synced.length, 1, "the open composer re-renders in place when commands arrive");
fetching.load("a");
same(pending.length, 0, "a fresh cache is reused");
vm.runInContext(`sessionItems[0].modelSettingsRevision = 2`, fetching);
fetching.load("a");
same(pending.length, 1, "a backend change refetches on the next slash entry");
vm.runInContext(`token = "t2"`, fetching);
fetching.load("a");
same(pending.length, 2, "a new pairing never reuses another pairing's cache");
pending[0].resolve({ ...fixture, revision: "stale" });
await settle();
same(fetching.cache.get("a").data, null, "a response for an earlier pairing is dropped");
pending.splice(0, 2)[1].reject(new Error("Offline"));
await settle();
same(fetching.cache.get("a").pending, 0, "a failure releases the tab for the next slash entry");
same(fetching.cache.get("a").data, null, "a failure shows nothing");
vm.runInContext(`selected = "b"`, fetching);
fetching.load("b");
pending.shift().resolve({ ...fixture, commands: [fixture.commands[0], { description: "missing name" }] });
await settle();
same(fetching.cache.get("b").data.commands.map(command => command.name), ["plan"], "rows without a name are ignored");
fetching.load("a");
same(pending.length, 1, "each tab has its own cache entry");
pending.shift().resolve({ error: "nope" });
await settle();
same(fetching.cache.get("a").data, null, "an invalid response is treated as a failure");

// @-mentions: the same rules as TabMentions on the Mac (query, matching, encoding, display).
const mentions = vm.createContext({ sessionItems: [], selected: null, token: "t", slashState: { open: false }, tabMentionLists: new Map() });
vm.runInContext(templateSlice("    const mentionTokenPattern=", "    function promptSlice"), mentions);
vm.runInContext(templateSlice("    function currentMentions(", "    function removeMention("), mentions);
const tv = "11111111-2222-3333-4444-555555555555", remote = "AAAAAAAA-2222-3333-4444-555555555555";
same(mentions.mentionQuery("mail a@b.com"), null, "an email address never opens the tab list");
same(mentions.mentionQuery("x@handle"), null, "an @ inside a word never opens the tab list");
same(mentions.mentionQuery("hi @ba"), { at: 3, query: "ba" }, "@ at a word start opens it");
same(mentions.mentionQuery("(@tv"), { at: 1, query: "tv" }, "@ after a bracket opens it");
same(mentions.mentionQuery("@ab cd", 3), { at: 0, query: "ab" }, "the query ends at the caret");
same(mentions.mentionQuery("hi @ "), null, "@ followed by a space is plain text");
same(mentions.mentionQuery("@[TV](x"), null, "a token is never a query");
same(mentions.mentionQuery("@" + "a".repeat(49)), null, "an @ far back is ignored");
same(mentions.mentionLabel("  Fix [the]\n TV  "), "Fix the TV", "labels are one line without brackets");
const candidates = [{ id: "1", title: "Sony TV", project: null }, { id: "2", title: "Bass Compass", project: "bass-compass" },
    { id: "3", title: "Café Ops", project: null }, { id: "4", title: "Cantrip", project: "Cantrip" }];
const titles = query => mentions.matchMentions(query, candidates).map(row => row.title);
same(titles("ba"), ["Bass Compass"], "@ba finds Bass Compass");
same(titles("bass c"), ["Bass Compass"], "words match word starts");
same(titles("cafe"), ["Café Ops"], "matching ignores diacritics");
same(titles("CA"), ["Café Ops", "Cantrip"], "title prefixes keep list order");
same(titles("bass x"), [], "no match");
const picks = [{ id: tv, label: "TV" }, { id: remote, label: "TV Remote" }];
const encoded = mentions.encodeMentions("ask @TV and @TV Remote, mail a@TV (@TV) @TVs", picks);
same(encoded, `ask @[TV](cantrip-tab:${tv}) and @[TV Remote](cantrip-tab:${remote}), mail a@TV (@[TV](cantrip-tab:${tv})) @TVs`,
    "picked mentions become tokens; longer labels first; never inside words");
same(mentions.plainMentions(encoded), "ask @TV and @TV Remote, mail a@TV (@TV) @TVs", "tokens read as @Label");
same(mentions.mentionProject("/Users/me"), null, "the home folder isn't a project");
same(mentions.mentionProject("/Users/me/Coding/Cantrip/"), "Cantrip", "the project is the folder name");
same(mentions.mentionPickedAt("Ask @Sony TV so", 4, [{ id: tv, label: "Sony TV" }]), true, "the list stays closed at a picked mention");
same(mentions.mentionPickedAt("@Sony TVs", 0, [{ id: tv, label: "Sony TV" }]), false, "a longer word isn't the pick");
same(mentions.uniqueMentionLabel({ id: remote, title: "Sony TV", project: "tv-two" }, [{ id: tv, label: "Sony TV" }]), "Sony TV (tv-two)",
    "a second tab with the same title gets its project");
same(mentions.uniqueMentionLabel({ id: remote, title: "Sony TV", project: null }, [{ id: tv, label: "Sony TV" }]), "Sony TV 2", "or a number");
same(mentions.uniqueMentionLabel({ id: tv, title: "Sony TV", project: null }, [{ id: tv, label: "Sony TV" }]), "Sony TV", "re-picking keeps the label");
same(mentions.uniqueMentionLabel({ id: remote, title: "x".repeat(70), project: null }, [{ id: tv, label: "x".repeat(60) }, { id: "c", label: "x".repeat(58) + " 2" }]),
    "x".repeat(58) + " 3", "a full-length title still gets a number that fits");
vm.runInContext(`selected = "tab"; tabMentionLists.set("tab", ${JSON.stringify(picks)}); var draftValue = "only @TV Remote here", rendered = 0;
  globalThis.$ = id => id === "draft" ? { get value() { return draftValue } } : null; globalThis.renderMentionChips = () => rendered++;`, mentions);
mentions.pruneMentions();
same(mentions.currentMentions().map(pick => pick.label), ["TV Remote"], "@TV Remote doesn't keep the @TV pick");
vm.runInContext(`draftValue = "x"`, mentions);
mentions.pruneMentions();
same(mentions.currentMentions(), [], "deleting a mention's text drops its chip");

// Privacy Gate: the route badge under prompts and the policy editor's section, on a minimal DOM.
{
    class FakeNode {
        constructor(tag) {
            Object.assign(this, { tagName: tag, children: [], attributes: {}, dataset: {}, className: "", textContent: "", value: "", disabled: false, checked: false, options: [], isConnected: true });
            const classes = new Set();
            this.classList = { toggle: (name, on) => { if (on) classes.add(name); else classes.delete(name) }, contains: name => classes.has(name) };
        }
        append(...items) { for (const item of items) { if (item?.tagName === "option") this.options.push(item); this.children.push(item) } }
        replaceChildren(...items) { for (const child of this.children) if (typeof child === "object") child.isConnected = false; this.children = []; this.append(...items) }
        setAttribute(name, value) { this.attributes[name] = String(value) }
        get text() { return this.textContent + this.children.map(child => typeof child === "string" ? child : child.text).join("") }
        all() { return this.children.flatMap(child => typeof child === "string" ? [] : [child, ...child.all()]) }
        querySelectorAll() { return this.all().filter(node => node.dataset.focusKey) }
        focus() { privacyDOM.focused = this }
    }
    const elements = {}, calls = [], posts = [];
    const tags = { privacyChatRoute: "select", privacyMode: "select", privacyGateEnabled: "input", policyEditor: "dialog" };
    const privacyDOM = { focused: null };
    const context = vm.createContext({
        privacyDOM, calls, posts,
        $: id => elements[id] || (elements[id] = Object.assign(new FakeNode(tags[id] || "div"), { id, open: id === "policyEditor" })),
        document: {
            body: new FakeNode("body"),
            get activeElement() { return privacyDOM.focused || this.body },
            createElement: tag => new FakeNode(tag),
            createElementNS: (_, tag) => new FakeNode(tag),
        },
        Option: class extends FakeNode { constructor(label, value) { super("option"); this.textContent = label; this.value = value } },
        api: async (path, options = {}) => {
            calls.push({ path, method: options.method || "GET" });
            if (path === "/api/v1/home/tasks") return { revision: "r1", tasks: [{ id: "11111111-1111-4111-8111-111111111111", title: "Morning digest" }] };
            if (path === "/api/v1/policy/privacy-test") return { ok: true, address: "https://llm-server.local/v1", model: "fixture-classifier", latencyMs: 412, route: "cloud", probabilities: { local: 0.02, cloud: 0.97, redactApprove: 0.01 } };
            throw new Error(`unexpected ${path}`);
        },
    });
    vm.runInContext(`var policyState=null,policySaving=false,privacyTasks=null,privacyTest=null,privacyFocus=null;
      async function policyPost(body,errorBox){posts.push({body,errorBox});return true}
      function el(tag,cls="",text){const n=document.createElement(tag);if(cls)n.className=cls;if(text!==undefined)n.textContent=text;return n}`, context);
    vm.runInContext(templateSlice("    // Privacy Gate: where each", "    function el(tag,cls=\"\",text)"), context);
    const run = code => vm.runInContext(code, context);
    const settle = () => new Promise(resolve => setTimeout(resolve, 0));
    context.$("privacyGate").append(...["privacyGateEnabled", "privacyMode", "privacyTest", "privacyChatRoute", "privacyTasks", "privacyRules"].map(id => context.$(id)));

    const badge = run(`privacyBadge({route:"local",mode:"enforce",applied:true,label:"Ran locally · secrets",detail:"Rule secrets matched in the request (3 ms)."})`);
    expect(badge.className.includes("privacy-badge") && badge.className.includes("enforce") && badge.className.includes("route-local"), "an enforced local badge uses the accent class");
    same([badge.title, badge.attributes.role, badge.text], ["Rule secrets matched in the request (3 ms).", "note", "Ran locally · secrets"], "the badge shows the label with the detail as its tooltip");
    expect(badge.attributes["aria-label"].includes("Ran locally · secrets") && badge.attributes["aria-label"].includes("Rule secrets matched"), "the badge's accessible label has the label and the detail");
    expect(badge.children[0].tagName === "svg" && badge.children[0].innerHTML.includes("path"), "each route has a glyph");
    const observed = run(`privacyBadge({route:"cloud",mode:"observe",applied:false,label:"Would run in the cloud",detail:"Classifier"})`);
    expect(observed.className.includes("observe") && !observed.className.includes("enforce"), "observe mode is quiet");
    const unknown = run(`privacyBadge({route:"elsewhere",mode:"observe",label:"",detail:""})`);
    expect(!unknown.className.includes("route-") && unknown.text === "Privacy check", "an unknown route still renders");
    const slot = run(`privacyBadge({label:"Privacy check"},true)`);
    expect(slot.className.includes("privacy-slot") && slot.attributes["aria-hidden"] === "true" && !slot.title, "a slot is invisible and silent");
    same(run(`privacyPendingID([{id:"a",role:"user",privacy:{route:"local"}},{id:"b",role:"assistant"},{id:"c",role:"user"},{id:"d",role:"assistant"}])`), "c",
        "the latest prompt without a badge holds its line once the conversation has badges");
    same(run(`privacyPendingID([{id:"a",role:"user"},{id:"b",role:"user"}])`), null, "conversations without badges reserve nothing");
    same(run(`privacyPendingID([{id:"a",role:"user"},{id:"b",role:"user",privacy:{route:"cloud"}}])`), null, "nothing is pending once the latest prompt has its badge");

    run(`renderPrivacyGate({policy:{revision:1,enabled:true,rules:[]}})`);
    expect(context.$("privacyGate").classList.contains("hidden"), "a Mac without the Privacy Gate hides the section");
    const stale = "22222222-2222-4222-8222-222222222222";
    run(`policyState={policy:{revision:7,privacyGate:{enabled:true,mode:"observe",appliesTo:["homeChat","homeTasks"],defaultRoute:"cloud",uncertainRoute:"redactApprove",
        classifier:{enabled:true,baseURL:"",model:"",timeoutMs:2500},chat:"auto",tasks:{"${stale}":"local"},stickyTurns:3,
        rules:[{id:"secrets",route:"local",enabled:true,detectors:["secret"],scope:["request","earlier","memory","context"]},{id:"personal-details",route:"redactApprove",enabled:false,detectors:["email","phone"],privateTerms:true},{id:"code",route:"cloud",enabled:true,repoWorkdir:true}]}},
      privacyClassifier:{address:"https://llm-server.local/v1",model:"fixture-classifier",from:"privateLocal",log:"~/.cache/Cantrip/privacy/decisions.jsonl"}};renderPrivacyGate(policyState)`);
    await settle();
    expect(!context.$("privacyGate").classList.contains("hidden"), "the section shows when the Mac has the Privacy Gate");
    same(context.$("privacyClassifier").textContent, "fixture-classifier at https://llm-server.local/v1, from Private Local", "the classifier says where it is");
    same([context.$("privacyGateEnabled").checked, context.$("privacyMode").value, context.$("privacyChatRoute").value, context.$("privacyChatRoute").options.length], [true, "observe", "auto", 4],
        "on, observing, and Home chat decides each time");
    same(calls.filter(call => call.path === "/api/v1/home/tasks").length, 1, "Home's tasks load once for the pickers");
    const taskRows = context.$("privacyTasks").children.filter(row => row.className === "privacy-route");
    same(taskRows.map(row => [row.children[0].textContent, row.children[1].value]), [["Morning digest", "auto"], ["A task that no longer exists", "local"]],
        "each task gets a picker, including a route left for a removed task");
    const ruleRows = context.$("privacyRules").children;
    same(ruleRows.map(row => [row.children[0].children[0].textContent, row.children[0].children[1].text, row.children[0].children[2].children[0].checked]),
        [["secrets", "Local", true], ["personal-details", "Ask first", false], ["code", "Cloud", true]], "rules show their ID, route and switch");
    expect(ruleRows[1].className.includes("off") && ruleRows[1].children[1].textContent.includes("email addresses") && ruleRows[1].children[1].textContent.includes("private terms"), "rules say what they match");

    ruleRows[1].children[0].children[2].children[0].checked = true;
    ruleRows[1].children[0].children[2].children[0].onchange();
    let post = posts.at(-1);
    same([post.errorBox, post.body.privacyGate.rules.map(rule => rule.enabled), post.body.privacyGate.mode, post.body.privacyGate.tasks, post.body.privacyGate.classifier.timeoutMs, post.body.privacyGate.stickyTurns],
        ["privacyGateError", [true, true, true], "observe", { [stale]: "local" }, 2500, 3], "a rule switch sends the whole section with one change");
    context.$("privacyMode").value = "enforce"; context.$("privacyMode").onchange();
    post = posts.at(-1);
    same([post.body.privacyGate.mode, post.body.privacyGate.rules[1].enabled, post.body.privacyGate.enabled], ["enforce", false, true], "the mode switch changes only the mode");
    context.$("privacyGateEnabled").checked = false; context.$("privacyGateEnabled").onchange();
    same(posts.at(-1).body.privacyGate.enabled, false, "the gate turns off");
    context.$("privacyChatRoute").value = "local"; context.$("privacyChatRoute").onchange();
    same(posts.at(-1).body, { privacyRoute: { task: null, route: "local" } }, "Home chat's route has no task");
    taskRows[0].children[1].value = "cloudWithPrivateTools"; taskRows[0].children[1].onchange();
    same(posts.at(-1).body, { privacyRoute: { task: "11111111-1111-4111-8111-111111111111", route: "cloudWithPrivateTools" } }, "a task's route names the task");
    run(`renderPrivacyGate(policyState)`);
    expect(context.privacyDOM.focused?.dataset.focusKey === "task:11111111-1111-4111-8111-111111111111" && context.privacyDOM.focused !== taskRows[0].children[1],
        "the re-rendered picker gets focus back");

    context.$("privacyTest").onclick();
    await settle();
    same(context.$("privacyTestResult").textContent, "Answered in 412 ms: Cloud · cloud probability 97%", "the test shows the route, latency and cloud probability");
    same(calls.at(-1), { path: "/api/v1/policy/privacy-test", method: "POST" }, "the test is a POST");
    same(run(`privacyTestText({ok:false,error:"The classifier timed out after 2500 ms."})`), "Didn't work: The classifier timed out after 2500 ms.", "a failed test shows the error");
    same(run(`privacyClassifierText({classifier:{enabled:true}},{from:"none",problem:"Private Local isn't set up.",log:"x"})`), "No classifier: Private Local isn't set up.", "a missing classifier says why");
}

console.log(failures === 0 ? `Web slash command tests passed (${passes})` : `${failures} web slash command tests failed`);
process.exit(failures === 0 ? 0 : 1);
