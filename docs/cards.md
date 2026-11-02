# Cards

Every card under a reply (weather, places, link previews, flights, and cards from tools) uses
one format: a **card document** made of a few building blocks. Each client draws each block
once, so a new kind of card needs no client code. Paired clients read them from `cards` on a
reply snapshot (`GET /api/v1/sessions/{id}`); the reply's main card comes first, then link cards.

The older keys (`placeCard`, `weatherCard`, `linkPreviews`) are still sent for clients from
before cards, and replies saved before cards are converted when they're sent, so old history
still draws.

## When a reply gets a card

The model decides by ending its reply with a fenced block, and Cantrip shows a card only when it
can resolve or check the data, so a wrong block shows nothing:

| Source | How | Values come from |
|---|---|---|
| `places` block | Names real places | MapKit and OpenStreetMap |
| `weather` block | Names a place | Open-Meteo |
| Link previews | Public links in the reply (up to three) | The page's Open Graph data, cached on the Mac |
| Tool results Cantrip knows | Automatic, e.g. a Kiwi.com `search-flight` result | The tool's result |
| `"cantrip/card"` in a tool's JSON result | Any tool (or MCP server) can return a ready card | The tool |
| `card` block | The model writes labels and copies values from a tool it cites | Checked against that tool's output |

A reply has at most one **main card**: a places card, else a weather card, else a checked
`card` block, else a tool card. Other `card` blocks, and any `card` block whose values aren't
all found in the cited tool's output, stay in the reply as plain text. Link cards for links the
main card already covers are dropped: a place's website or a link named for a place, weather
sites under a forecast, and pages on the same site as one of the card's actions.

Cards are for answers whose core is real structured data that's easier to see than read
(places, forecasts, flights, packages, prices), never for prose.

### The `card` block

```card
{"title": "Package 1Z999", "cite": {"tool": "track_package"},
 "blocks": [{"type": "keyValue", "rows": [{"key": "Status", "value": "In transit"}]}]}
```

`title` and `subtitle` become a header. Models may use `header`, `stat`, `keyValue`, `list`,
`strip`, `chart`, `badges` and `notice` blocks (no maps or images). Every number, time and link
in the card must appear in the cited tool's output; words are labels and pass.

### Tool cards and MCP Apps

A tool can put a card document under the key `"cantrip/card"` at the top level of its JSON
result. Cantrip shows it as the tool's card (images and unknown blocks are dropped). This is
separate from, and works next to, [MCP Apps](https://github.com/modelcontextprotocol/ext-apps)
HTML views (`ui://` resources), which Cantrip already shows for Copilot.

## Document

```json
{"version": 1, "id": "…", "type": "weather", "style": "panel",
 "accessibilityLabel": "Weather for Seattle, WA",
 "action": {"kind": "open", "label": "Open", "url": "https://…"},
 "source": {"kind": "resolver", "name": "Open-Meteo", "attribution": "Weather data by Open-Meteo.com",
            "url": "https://open-meteo.com/", "updatedAt": "2026-11-01T22:15:00Z"},
 "fallbackText": "…",
 "blocks": [ … ]}
```

- `type` names the card for logs and tests; clients never branch on it.
- `style`: `panel` (default) or `link` (a compact card; the whole card opens `action.url`).
- `source.kind`: `resolver`, `tool` or `preview`. A panel card with `attribution` or
  `updatedAt` ends with a footer: "Updated 3:39 PM" and the attribution, linked to `url`.
- `fallbackText`: the card as plain text, for a client that can't draw it.
- Actions open their `url` only when it's `https`, `http` or `tel`.

## Blocks

| Block | Fields | Drawn as |
|---|---|---|
| `header` | `title`, `subtitle`, `subtitleSymbol`, `symbol`, `lines`, `stat` | Title (15 pt semibold), subtitle with its icon, then `lines` (first 13 pt, others 12 pt muted); a leading icon for `symbol`; `stat` on the trailing side (icon and 40 pt light value) |
| `stat` | `value`, `label`, `symbol`, `detail`, `accessibilityLabel` | A big value (34 pt light) with its icon, label above and detail below |
| `keyValue` | `rows: [{key, value, symbol}]` | Rows: muted key on the leading side, value on the trailing side |
| `strip` | `items: [{label, symbol, value, note, accessibilityLabel}]` | A horizontally scrolling strip of 52 pt columns: label, icon, note (blue), value |
| `chart` | `kind` (`range` or `bar`), `min`, `max`, `items: [{label, symbol, note, low, high, lowText, highText}]` | Rows with a bar from `low` to `high` on the `min`…`max` scale (blue to yellow), `lowText` and `highText` beside it |
| `list` | `title`, `mapLinked`, `items: [{id, title, subtitle, detail, symbol, glyph, badges, note, tone, trailing, pinID, actions}]` | Rows: title, subtitle, badges, detail, note (tinted by `tone`), `trailing` on the trailing side, action buttons |
| `map` | `latitude`, `longitude`, `latitudeDelta`, `longitudeDelta`, `pins: [{id, title, latitude, longitude, glyph, symbol}]`, `attribution` | An interactive map with labeled pins, zoom buttons and the attribution |
| `image` | `imageID`, `aspectRatio` | A hero image from `GET /api/v1/link-previews/image?id=`; only images the Mac cached |
| `badges` | `badges: [{text, tone, symbol}]` | A wrapping row of pills |
| `notice` | `symbol`, `title`, `text`, `tone` | A status message, such as "Forecast unavailable" and why |

A `list` with `mapLinked: true` right after a `map` is that map's legend: its items' `pinID`s
are the map's pins. Where the card is at least 600 pt wide the list floats over the map,
otherwise it sits under it; choosing a row focuses its pin.

Badge and note tones: `positive` green, `negative` red, `warning` amber, `accent` blue,
`neutral` muted. Symbols are SF Symbol names; the web and Windows clients map the ones Cantrip
uses to Lucide icons and otherwise draw `glyph` (an emoji) when there is one.

Every row and strip item has an `accessibilityLabel` (VoiceOver and screen readers read it
instead of the separate fields), and the card's own label names it. Clients skip block types
they don't know; a card with nothing they can draw shows its `fallbackText`.

Panel cards share the map card's geometry: up to 680 pt wide (760 px on the web), 16 pt corners,
a 1 pt border at 14% opacity, always dark, with white text at AA contrast.

## Cards on Cantrip Home

Scheduled-task and incident runs keep their cards with their results
(`cards` on Background runs and on a task's runs), and workspaces show cards
built from their records (`workspaceCards` in the tasks snapshot, and a
record's weather and map cards from `GET /api/v1/home/tasks/<task>/records/<record>/cards`).
`source.kind` is `records` for a card built from a workspace's records. Clients
draw them with the same block views; see [Cantrip Home](cantrip-home.md#background-runs).

## Clients

Each client has one view per block and nothing per card type:

| Client | Renderer | Notes |
|---|---|---|
| Mac launcher | `Sources/Cantrip/CardViews.swift` | MapKit map; link cards reuse the link preview card |
| Browser Remote | `appendCards` in `RemoteControlServer.swift` | OpenStreetMap tiles through the Mac; Lucide icons |
| Cantrip Agent (iPhone, Duo) and Cantrip Gateway for Mac | `CantripCards.swift` in the iOS app | Older Macs' `weatherCard`, `placeCard` and `linkPreviews` are drawn as the same blocks |
| Cantrip Gateway for Windows | `windows/src/gateway/ui/transcript/Cards.tsx` in the Gateway repo | `tel:` actions show the number as text |
| Cantrip for Windows | `windows/src/renderer/cards.ts` | No Mac: weather only, built in its main process; `map` and `image` blocks are skipped |

Actions open only `https`, `http` and `tel` URLs (public hosts only), on every client.
