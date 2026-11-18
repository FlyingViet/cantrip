[User Guide](README.md) / Views

# Views

A **view** is a screen Cantrip Home builds for you on request: a dashboard, a status board or a
comparison table, drawn natively on every client from live data. Ask Home for one ("make me a
view of this week across my trackers", "a homelab status board", "compare these three laptops in
a table") and it appears under **Tasks → Views** on Cantrip Agent (iPhone, iPad, Duo), Cantrip
Gateway for Mac and Windows, Cantrip for Windows' Home window and the browser remote. Pin the ones
you use most; they stay first.

No model-written code ever runs. A view is a declarative JSON template that Cantrip validates
against a versioned schema, and every value on it comes from a **binding** Cantrip evaluates
itself: a Home task's records, a read-only tool Cantrip calls, a tool result a task run produced,
or a tool result checked when the view was made. A model writes labels and layout, never values.

## Design at a glance

| Part | Decision |
|---|---|
| Schema | `cantrip-view` fenced block in Home (version 1): `name`, `icon`, `data` (named sources), `blocks` (card blocks whose values are bindings), optional `refresh` and `pinned`. Invalid blocks get one hidden repair turn, like other Home blocks |
| Rendering | Cantrip resolves the template into an ordinary [card document](cards.md) and clients draw it with their card block views. New blocks: `table`, `section`, `tabs`, `actions`, and `line`/`pie` chart kinds. Old clients skip what they don't know |
| Bindings | `records` (a workspace's records), `tasks` (tasks with record counts and run state), `tool` (a saved read-only tool call), `run` (a tool's output from a task's latest run), `checked` (rows the model copied from a tool result in the same reply, checked like a `card` block) |
| Refresh | Records and tasks are read live each time a view is built. Tool data refreshes when someone opens a view older than `refresh.everyMinutes` (default 30), on **Refresh**, and after runs of the tasks in `refresh.afterTasks`. A `run` source updates when its task's run finishes. No model is involved in a refresh |
| Actions | `actions` block buttons: open a link, run a task now, refresh, open a record, ask Home a prefilled question. Every button asks for confirmation on the client and runs on the Mac (`POST …/actions/<id>` with `confirmed: true`) |
| Storage | `~/.cache/Cantrip/home/views.json` (0600): templates, pin state, and each tool source's last output |
| API | `GET /api/v1/home/views[?revision=]`, `GET/DELETE /api/v1/home/views/<id>`, `POST …/<id>/refresh`, `POST …/<id>/pin`, `POST …/<id>/actions/<action id>`; tasks snapshot `supportsViews` |
| Privacy | Refreshing never sends data to a model, and Home's model never sees a view's values (only names, IDs and sources). Tool sources use only read-only tools, through the MCP relay with Home's per-tab switches and the agent policy. A view reading a private server (`personal`, or one the Privacy Gate keeps from cloud runs) is marked private |

## Asking for a view

Tell Home what you want to see and from where; it asks about anything it can't tell. Examples:

- "Make a *This week* view: interviews by stage as a pie, and how many follow-ups, trips and bills
  each tracker holds."
- "A homelab status board from homelab_status, refreshed every 15 minutes, with a Refresh button."
- "Compare the three laptops we just looked at in a table" (a one-off view from the reply's own
  tool results).

Home replies with a preview of the view and saves it; pin it from the view's screen (or ask Home to).
To change one, ask Home ("add a bills chart to This week"); it sends the whole template again
with the view's `id`. Delete it from its screen.

## The `cantrip-view` block

```json
{"id": null, "name": "Homelab", "icon": "server.rack", "pinned": true,
 "refresh": {"everyMinutes": 15, "afterTasks": []},
 "data": {
   "lab": {"tool": {"server": "homelab", "name": "homelab_status", "arguments": {}}}
 },
 "blocks": [
   {"type": "stat", "label": "Services up", "value": {"from": "lab", "count": true, "where": {"ok": ["true"]}}},
   {"type": "table", "from": "lab", "columns": [
     {"title": "Service", "field": "key"},
     {"title": "Status", "field": "ok", "labels": {"true": "Up", "false": "Down"},
      "tones": {"true": "positive", "false": "negative"}},
     {"title": "Version", "field": "version"}]},
   {"type": "actions", "buttons": [{"kind": "refresh", "label": "Refresh"}]}
 ]}
```

- `id`: null to create, or an existing view's ID to replace its template (pin state is kept unless
  `pinned` is sent). Up to 30 views.
- `name` (1–60 characters), `subtitle`, `icon` (SF Symbol; clients map it), `pinned`.
- `refresh`: `everyMinutes` (5–1440, default 30) and `afterTasks` (task IDs).
- `data`: up to 8 named sources (letters, digits, `_`), at most 4 of them `tool` sources.
- `blocks`: up to 40, nested ones included.

### Sources

| Source | Shape | Rows |
|---|---|---|
| `records` | `{"records": "<task ID>", "filter": {"choiceField": ["Option"]}, "dateField": "due", "withinDays": 7, "includeOverdue": true}` (everything but `records` optional; `withinDays` needs `dateField`) | One per record: its field keys, plus `_id`, `_created`, `_updated` |
| `tasks` | `{"tasks": ["<task ID>", …]}` (up to 20) | One per task: `id`, `title`, `records` (count), `state`, `enabled`, `lastRun` (status), `lastRunAt`, `nextRunAt`, `schedule` |
| `tool` | `{"tool": {"server": "…", "name": "…", "arguments": {…}}, "path": "data.items"}` | The tool's JSON at `path` (dots and indexes, `items.0.name`). An array gives a row per element (a value that isn't an object becomes `{"value": …}`); an object of objects gives a row per entry (sorted by name) with its name in `key`; another object is one row |
| `run` | `{"run": {"taskID": "<task ID>", "tool": "tool name"}, "path": "…"}` | As `tool`, from that tool's newest successful output in the task's latest run |
| `checked` | `{"checked": {"tool": "tool name"}, "rows": [{"name": "…", "price": "$1,299"}]}` | The rows as written. Saved only when every value with a number, time or link appears in that tool's output from the same reply, as written or by the `card` block's number check; never refreshed |

A `tool` source may name only a read-only tool (no word in its name that changes, sends or runs
anything, and a read word or a read-only server) of an enabled server Cantrip may offer Private
Local (never password, browser, file or build servers), and the agent policy must not deny it.

### Values

Blocks never carry typed values. A **value slot** (a stat's `value`, a `keyValue` row's `value`)
takes a binding:

```json
{"from": "jobs", "count": true, "where": {"stage": ["Onsite"]}}
{"from": "spend", "sum": "amount", "prefix": "$", "decimals": 2}
{"from": "lab", "path": "nas.documents"}
{"from": "trackers", "field": "records", "where": {"title": ["Trip tracker"]}}
```

One of `count`, `sum`, `min`, `max`, `avg` (a field), `field` (the first matching row's field) or
`path` (into the source's JSON); optional `where` (field → values, case-insensitive), `prefix`,
`suffix`, `decimals` (0–4), `labels`.

Collection blocks take `from`, optional `where`, `sort` (a field), `descending`, `limit`, and
`groupBy` (a field: rows become `label`, `count`, and `sum` when `sum` names a field). Field
values are shown as they are, except ISO dates (`Tue, Nov 18`, with the time when there is one),
`true`/`false` (`Yes`/`No`) and numbers (grouped; `decimals`, `prefix`, `suffix`). `labels` maps
raw values to words, and `tones` maps raw values to `positive`, `negative`, `warning`, `accent` or
`neutral`.

Text the model writes (titles, labels, column names, notices, button labels) can't contain a
number unless it's one of the view's own settings (a `withinDays`, `limit` or `everyMinutes`), so
"Next 7 days" is fine with `withinDays: 7` and "42 open" is refused.

### Blocks

| Block | Template fields |
|---|---|
| `header` | `title`, `subtitle`, `symbol`, `lines` (text) |
| `section` | `title`, `subtitle`, `symbol`, `blocks` (its contents) |
| `tabs` | `tabs: [{"title", "symbol", "blocks": […]}]` (2–6 tabs) |
| `stat` | `label`, `symbol`, `value` (binding), `detail` (text or binding) |
| `keyValue` | `rows: [{"key", "value": binding, "symbol"}]`, or `from` + `labelField` + `valueField` |
| `list` | `title`, `from`, `titleField`, `subtitleFields` (≤ 3), `detailField`, `trailingField`, `badgeField`, `tones`, `limit` (≤ 20) |
| `table` | `title`, `from`, `columns: [{"title", "field", "align", "labels", "tones", "prefix", "suffix", "decimals"}]` (≤ 6), `limit` (≤ 50) |
| `chart` | `kind` (`bar`, `line`, `pie`), `title`, `from`, `labelField` + `valueField`, or `groupBy` (+ `sum`), `limit` (bar ≤ 24, line ≤ 60, pie ≤ 8 slices; the rest become Other) |
| `badges` | `from`, `textField`, `tones` |
| `notice` | `title`, `text`, `symbol`, `tone` |
| `actions` | `buttons: [{"kind", "label", "symbol", …}]` (≤ 6): `open` + `url` (a public web page), `runTask` + `taskID`, `refresh`, `openRecord` + `taskID` + `recordID`, `ask` + `prompt` (≤ 500 characters) |

An empty collection shows a notice ("Nothing to show"), and a source that fails shows a warning
notice in place of its blocks, so a view never shows stale values as current: its footer says when
its data was read.

## What clients get

Clients never evaluate bindings. `GET /api/v1/home/views/<id>` answers:

```json
{"view": {"id": "…", "name": "Homelab", "subtitle": null, "icon": "server.rack", "pinned": true,
          "private": false, "sources": ["tool"], "createdAt": "…", "updatedAt": "…",
          "refreshedAt": "…", "refreshing": false, "problems": []},
 "card": {"version": 1, "id": "view-…", "type": "view", "source": {"kind": "view", "name": "Homelab", "updatedAt": "…"},
          "fallbackText": "…", "blocks": [ … ]},
 "refreshAfter": 30}
```

`card` is an ordinary card document, drawn with the card block views (up to 48 blocks for a view).
While a view is open, clients fetch it again every `refreshAfter` seconds. A view's card ID is
`view-<view id>`; its `actions` buttons post to that view.

- `GET /api/v1/home/views[?revision=]`: `{"views": [summary…], "revision", "supportsViewActions": true}`
  (pinned first, then newest), or `{"unchanged": true, "revision"}`.
- `POST /api/v1/home/views/<id>/refresh`: refreshes its tool sources (waits up to 20 s) and answers
  like `GET`.
- `POST /api/v1/home/views/<id>/pin` `{"pinned": true}`: the summary.
- `DELETE /api/v1/home/views/<id>`: `{"deleted": true}`.
- `POST /api/v1/home/views/<id>/actions/<action id>` `{"confirmed": true}`: without `confirmed`
  the Mac answers 428 with the confirmation text and does nothing. Results:
  `{"result": "open", "url"}` (the client opens it), `{"result": "record", "taskID", "recordID"}`
  (the client shows the record), `{"result": "started", "message"}` (the task's run is queued),
  `{"result": "refreshed", "view", "card"}`, `{"result": "sent", "message"}` (the question is in Home's
  chat; the client switches to it).

The tasks snapshot carries `"supportsViews": true`; clients show Views only then.

### New blocks in resolved cards

| Block | Fields | Drawn as |
|---|---|---|
| `section` | `title`, `subtitle`, `symbol` | A grouped-list heading that starts a group: 13 pt semibold title at 72% white with its icon, subtitle 12 pt at 60%, 18 pt above |
| `tabs` | `tabs: [{title, symbol, count}]` | A segmented control; the next `count` blocks belong to each tab in turn, and only the selected tab's blocks show (the first tab at first). Clients without it show every block in order |
| `table` | `title`, `columns: [{title, align}]`, `tableRows: [{id, cells: [{text, tone, symbol}], accessibilityLabel}]` | A header row (12 pt semibold, 60% white) and rows of 13 pt cells with hairlines between them, `align` `leading`/`trailing`/`center`, a cell's text tinted by its `tone`; scrolls sideways when it doesn't fit. VoiceOver reads each row's `accessibilityLabel` |
| `chart` `line` | `title`, `min`, `max`, `items: [{label, high, highText, accessibilityLabel}]` | One line through the points in order (accent blue, 2 pt, dots at each point), the `min`…`max` scale, the first, middle and last labels under it; each point is an accessibility element |
| `chart` `pie` | `title`, `items: [{label, high, highText, tone, accessibilityLabel}]` | A donut (the item's `tone`, else the palette in order: `#4C9DFF`, `#34C759`, `#FFCC00`, `#AF52DE`, `#5AC8FA`, `#FF9F0A`, `#FF6482`, `#8E8E93`) with a legend: label, `highText` and its percentage |
| `actions` | `buttons: [{id, kind, label, symbol, style, confirmTitle, confirmMessage}]` | A wrapping row of bordered buttons (`style` `prominent`: filled accent). Choosing one shows a confirmation (`confirmTitle`, `confirmMessage`, the button's label to go ahead, Cancel), then posts the action. Clients hide kinds they don't know |

`line` and `pie` charts also carry `low: 0` and a `max`, so clients that only know `bar` charts
draw them as bars. A chart or table may carry a `title` (13 pt semibold, above it).

## Privacy and cost

- Refreshing a view calls a read-only tool or reads records on the Mac and sends the result only to
  your paired clients. No model reads a view's values, so a view never costs tokens after it's made.
- Home's model is told each view's name, ID and sources, never its values.
- Tool sources run through the MCP relay as Home (its per-tab server switches apply) and the agent
  policy. A tool the policy denies or asks about, or whose name says it writes, is refused when the
  view is saved; Cantrip calls a tool only if Private Local's read-only check would offer it (a read
  word in its name, or a server that marks it read-only), otherwise the view shows why.
- A view with a source on a private server (`personal`, or a server the Privacy Gate keeps from
  cloud runs) is marked **private**: clients show a lock, and its data stays in views.json on the
  Mac.
- `run` sources take what a task's run already read; that run goes through the Privacy Gate as
  usual. `ask` buttons send only the question Home wrote, never the view's values.

## Clients

| Client | Views | Blocks |
|---|---|---|
| Cantrip Agent (iPhone, iPad, Duo) and Cantrip Gateway for Mac (and the Mac's Home window) | Tasks → Views, pinned first; the view's screen has Refresh, Pin and Delete | `CantripCards.swift` |
| Browser remote | Tasks panel → Views | `appendCards` in `RemoteControlServer.swift` |
| Cantrip Gateway for Windows | Tasks → Views | `Cards.tsx` |
| Cantrip for Windows | Home window → Views (read-only window: Refresh and links) | `windows/src/renderer/cards.ts` |
| Mac launcher | (views live in Home) | `CardViews.swift` draws the new blocks in any card |
