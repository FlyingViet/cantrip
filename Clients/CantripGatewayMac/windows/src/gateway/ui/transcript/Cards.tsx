// Generic cards (`RemoteMessage.cards`, docs/cards.md): one component per block, so a new kind of card
// needs no code here. Panel cards share the weather card's container; `link` cards look like link
// previews. Strings are only ever drawn as text, and actions open public http(s) pages only. A view's
// card (docs/views.md) also draws its `actions` buttons, which only run through the view's `onAction`.
import { signal } from "@preact/signals";
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { RemoteCardAction, RemoteCardBadge, RemoteCardBlock, RemoteCardDocument, RemoteCardItem } from "../../api/types";
import { bridge } from "../../bridge";
import { Icon, symbolIcon } from "../icons";
import { confirmDialog } from "../kit";
import { MapComposition, type LegendState, type MapSpec } from "./CardMap";
import {
  actionSymbol, buttonSymbol, cardBadges, cardButtons, cardFallback, cardFooter, cardGlyph, cardItems, cardLabel, cardLines, cardParts,
  cardRows, cardStyle, cardTable, cardText, cardTone, chartBar, chartColumns, chartScale, itemLabel, lineChart, mapAttribution, mapPins,
  mapRegion, pieSlices, progressState, safeActionUrl, statLabel, telNumber, VIEW_ACTION_KINDS, type CardButtonModel, type CardPart,
} from "./cardLogic";
import { LinkDomain, useLinkPreviewImage } from "./RichCards";
import { weatherIcon, weatherTint } from "./richCardLogic";

type SymbolSize = 12 | 14 | 16 | 18 | 24 | 28;

/** An SF Symbol as its Lucide icon (weather icons tinted like the forecast), else the emoji, else nothing. */
function symbolNode(symbol: unknown, glyph: unknown, size: SymbolSize, tint = false): JSX.Element | null {
  const icon = symbolIcon(symbol);
  if (icon) {
    const drawn = <Icon name={icon} size={size} />;
    return tint && weatherIcon(icon) === icon ? <span class={`weather-glyph ${weatherTint(icon)}`}>{drawn}</span> : drawn;
  }
  const emoji = cardGlyph(glyph);
  return emoji ? <span class={`card-glyph s${size}`} aria-hidden="true">{emoji}</span> : null;
}

/** Every card under a reply, in order: the main card first, then link cards. */
export function CardStack(props: { cards: RemoteCardDocument[] | undefined }): JSX.Element | null {
  const cards = (Array.isArray(props.cards) ? props.cards : []).filter((card) => card && typeof card === "object");
  if (!cards.length) return null;
  return (
    <div class="card-stack">
      {cards.map((card, index) => <CardView key={`${index}:${typeof card.id === "string" ? card.id : ""}`} card={card} />)}
    </div>
  );
}

/** Runs a view's `actions` button once the user confirmed it (the view posts it to the Mac). */
export type CardActionHandler = (button: CardButtonModel) => Promise<unknown> | void;

/**
 * A card. `onAction` is the view the card belongs to: only then are its `actions` buttons drawn (`actionKinds`, the
 * kinds this client runs); a chat reply's card never shows them.
 */
export function CardView(props: { card: RemoteCardDocument; onAction?: CardActionHandler; actionKinds?: ReadonlySet<string> }): JSX.Element | null {
  const { card, onAction } = props;
  const parts = cardParts(card, { actionKinds: onAction ? props.actionKinds ?? VIEW_ACTION_KINDS : undefined });
  if (!parts.length) {
    const fallback = cardFallback(card);
    return fallback ? <div class="card-fallback selectable">{fallback}</div> : null;
  }
  return cardStyle(card) === "link" ? <LinkCard card={card} parts={parts} />
    : <PanelCard card={card} parts={parts} onAction={onAction} actionKinds={props.actionKinds ?? VIEW_ACTION_KINDS} />;
}

const FLOW_BLOCKS = new Set(["header", "stat", "notice", "badges", "progress", "actions"]);

interface PartContext {
  onAction?: CardActionHandler;
  actionKinds: ReadonlySet<string>;
}

function PanelCard(props: { card: RemoteCardDocument; parts: CardPart[]; onAction?: CardActionHandler; actionKinds: ReadonlySet<string> }): JSX.Element {
  const { card, parts } = props;
  const footer = cardFooter(card.source);
  const context: PartContext = { onAction: props.onAction, actionKinds: props.actionKinds };
  return (
    <section class="card-panel" aria-label={cardLabel(card)}>
      <CardParts parts={parts} keyPrefix={typeof card.id === "string" ? card.id : ""} context={context} />
      {footer ? (
        <div class="card-foot">
          {footer.updated ? <span>{footer.updated}</span> : null}
          {footer.attribution && footer.url ? (
            <button type="button" class="card-attr" onClick={() => bridge.openExternal(footer.url!)}>{footer.attribution}</button>
          ) : footer.attribution ? (
            <span class="card-attr static">{footer.attribution}</span>
          ) : null}
        </div>
      ) : null}
    </section>
  );
}

/** A card's parts in order; a tabs part draws its selected tab's parts the same way. */
function CardParts(props: { parts: CardPart[]; keyPrefix: string; context: PartContext }): JSX.Element {
  const { parts, keyPrefix, context } = props;
  return (
    <>
      {parts.map((part, index) => {
        const stateKey = `${keyPrefix}:${index}`;
        const divided = part.divided ? " card-divided" : "";
        if (part.kind === "map") {
          return (
            <div key={index} class={`card-block card-map${divided}`}>
              <MapBlock map={part.map} legend={part.legend} />
            </div>
          );
        }
        if (part.kind === "tabs") {
          return (
            <div key={index} class={`card-block card-tabs-block${divided}`}>
              <TabsBlock part={part} stateKey={stateKey}
                panel={(parts, key) => <CardParts parts={parts} keyPrefix={key} context={context} />} />
            </div>
          );
        }
        const flow = FLOW_BLOCKS.has(part.block.type);
        return (
          <div key={index} class={`card-block card-${part.block.type}-block${flow ? " card-flow" : ""}${divided}`}>
            <BlockView block={part.block} stateKey={stateKey} context={context} />
          </div>
        );
      })}
    </>
  );
}

/** A compact card for a link: its image and title; the whole card opens the page. */
function LinkCard(props: { card: RemoteCardDocument; parts: CardPart[] }): JSX.Element {
  const { card, parts } = props;
  const url = safeActionUrl(card.action);
  const content = parts.map((part, index) => {
    if (part.kind !== "block") return null;
    const { block } = part;
    if (block.type === "image") return <CardImage key={index} block={block} hero />;
    if (block.type === "header") return <LinkHeader key={index} block={block} />;
    return <div key={index} class={`card-link-extra card-${block.type}-block`}><BlockView block={block} /></div>;
  });
  const label = cardLabel(card);
  return url ? (
    <button type="button" class="link-preview-card card-link" role="link" aria-label={label} onClick={() => bridge.openExternal(url)}>
      {content}
    </button>
  ) : (
    <section class="link-preview-card card-link static" aria-label={label}>{content}</section>
  );
}

function LinkHeader(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const lead = symbolNode(block.symbol, undefined, 18);
  const lines = cardLines(block);
  return (
    <div class={`link-preview-meta${lead ? " card-link-meta" : ""}`}>
      {lead ? <span class="card-link-symbol" aria-hidden="true">{lead}</span> : null}
      <div class="card-link-text">
        {cardText(block.title) ? <div class="link-preview-title">{cardText(block.title)}</div> : null}
        {cardText(block.subtitle) ? <LinkDomain text={cardText(block.subtitle)!} iconID={block.subtitleImageID} /> : null}
        {lines.map((line, index) => <div key={index} class="link-preview-domain">{line}</div>)}
      </div>
    </div>
  );
}

function BlockView(props: { block: RemoteCardBlock; stateKey?: string; context?: PartContext }): JSX.Element | null {
  const { block, context } = props;
  switch (block.type) {
    case "header": return <HeaderBlock block={block} />;
    case "stat": return <StatBlock block={block} />;
    case "keyValue": return <KeyValueBlock block={block} />;
    case "strip": return <StripBlock block={block} />;
    case "chart": return block.kind === "line" ? <LineChartBlock block={block} />
      : block.kind === "pie" ? <PieChartBlock block={block} />
        : <ChartBlock block={block} />;
    case "section": return <SectionBlock block={block} />;
    case "table": return <TableBlock block={block} />;
    case "actions": return context?.onAction
      ? <ActionsBlock block={block} onAction={context.onAction} kinds={context.actionKinds} stateKey={props.stateKey ?? ""} />
      : null;
    case "list": return block.collapsed === true && cardText(block.title) && props.stateKey
      ? <CollapsedList block={block} stateKey={props.stateKey} />
      : <ListBlock block={block} />;
    case "image": return <CardImage block={block} />;
    case "badges": return <Badges badges={block.badges} />;
    case "notice": return <NoticeBlock block={block} />;
    case "progress": return <ProgressBlock block={block} />;
    default: return null;
  }
}

function HeaderBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const title = cardText(block.title), subtitle = cardText(block.subtitle);
  const lines = cardLines(block);
  const stat = block.stat && typeof block.stat === "object" && cardText(block.stat.value) ? block.stat : undefined;
  const lead = symbolNode(block.symbol, undefined, 18, true);
  return (
    <div class="card-head">
      {lead ? <span class={`card-head-symbol${block.tone ? ` tone-${cardTone(block.tone)}` : ""}`} aria-hidden="true">{lead}</span> : null}
      <div class="card-head-info">
        {title ? <div class="card-title" role="heading" aria-level={3}>{title}</div> : null}
        {subtitle ? <div class="card-subtitle">{symbolNode(block.subtitleSymbol, undefined, 12)}{subtitle}</div> : null}
        {lines.map((line, index) => <div key={index} class={index === 0 ? "card-line" : "card-line-more"}>{line}</div>)}
      </div>
      {stat ? (
        <div class="card-now" role="img" aria-label={statLabel(stat)}>
          {symbolNode(stat.symbol, undefined, 28, true)}
          <span class="card-now-value">{cardText(stat.value)}</span>
        </div>
      ) : null}
    </div>
  );
}

function StatBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const label = cardText(block.label), detail = cardText(block.detail);
  const icon = symbolNode(block.symbol, undefined, 24, true);
  return (
    <div class="card-stat" role="img" aria-label={statLabel({ value: cardText(block.value) ?? "", label, detail, accessibilityLabel: block.accessibilityLabel })}>
      {label ? <div class="card-stat-label">{label}</div> : null}
      <div class="card-stat-row">
        {icon ? <span class="card-stat-symbol">{icon}</span> : null}
        <span class="card-stat-value">{cardText(block.value)}</span>
      </div>
      {detail ? <div class="card-stat-detail">{detail}</div> : null}
    </div>
  );
}

function KeyValueBlock(props: { block: RemoteCardBlock }): JSX.Element {
  return (
    <dl class="card-kv" aria-label={cardText(props.block.accessibilityLabel)}>
      {cardRows(props.block).map((row, index) => (
        <div key={index} class="card-kv-row">
          <dt>{symbolNode(row.symbol, undefined, 14)}{row.key}</dt>
          <dd>{row.value}</dd>
        </div>
      ))}
    </dl>
  );
}

function StripBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const items = cardItems(props.block);
  return (
    <div class="card-strip" role="list" aria-label={cardText(props.block.accessibilityLabel)}>
      {items.map((item, index) => (
        <div key={index} class="card-strip-item" role="listitem" aria-label={itemLabel(item, "strip")}>
          <span class="card-strip-label">{cardText(item.label)}</span>
          {symbolNode(item.symbol, item.glyph, 18, true) ?? <span class="card-strip-blank" />}
          <span class="card-note">{cardText(item.note)}</span>
          <span class="card-strip-value">{cardText(item.value)}</span>
        </div>
      ))}
    </div>
  );
}

function ChartBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const items = cardItems(block);
  const scale = chartScale(block);
  const columns = chartColumns(items);
  const symbols = items.some((item) => typeof item.symbol === "string" && item.symbol);
  const notes = items.some((item) => cardText(item.note));
  const title = cardText(block.title);
  return (
    <>
    {title ? <div class="card-block-title">{title}</div> : null}
    <div class="card-chart" role="list" aria-label={cardText(block.accessibilityLabel) ?? title}>
      {items.map((item, index) => {
        const bar = chartBar(item, scale, block.kind);
        return (
          <div key={index} class="card-chart-row" role="listitem" aria-label={itemLabel(item, "chart")} style={{ gridTemplateColumns: columns }}>
            <span class="card-chart-label">{cardText(item.label)}</span>
            {symbols ? <span class="card-chart-symbol">{symbolNode(item.symbol, item.glyph, 16, true)}</span> : null}
            {notes ? <span class="card-note">{cardText(item.note)}</span> : null}
            <span class="card-chart-low">{cardText(item.lowText)}</span>
            <span class="card-chart-bar" aria-hidden="true">
              {bar ? <span style={{ left: `${bar.left}%`, width: `${bar.width}%` }} /> : null}
            </span>
            <span class="card-chart-high">{cardText(item.highText)}</span>
          </div>
        );
      })}
    </div>
    </>
  );
}

function ListBlock(props: { block: RemoteCardBlock; legend?: LegendState }): JSX.Element {
  const { block, legend } = props;
  const title = cardText(block.title);
  return (
    <div class="card-list">
      {title ? <div class="card-list-title">{title}</div> : null}
      <div role="list" aria-label={title ?? cardText(block.accessibilityLabel)}>
        {cardItems(block).filter((item) => cardText(item.title)).map((item, index) => (
          <ListRow key={typeof item.id === "string" ? item.id : index} item={item} legend={legend} />
        ))}
      </div>
    </div>
  );
}

/** Collapsed lists the user opened, by card and block, while the app runs (a card that updates in place stays open). */
const openedLists = new Set<string>();

/** A list that starts collapsed to its title and summary (a build card's Earlier steps). */
function CollapsedList(props: { block: RemoteCardBlock; stateKey: string }): JSX.Element {
  const { block, stateKey } = props;
  const [open, setOpen] = useState(() => openedLists.has(stateKey));
  const title = cardText(block.title)!;
  const summary = cardText(block.subtitle);
  const toggle = () => {
    const next = !open;
    if (next) openedLists.add(stateKey);
    else openedLists.delete(stateKey);
    setOpen(next);
  };
  return (
    <div class="card-list card-list-collapsible">
      <button type="button" class="card-list-toggle" aria-expanded={open} onClick={toggle}>
        <Icon name="chevron.right" size={12} class={`card-list-chevron${open ? " open" : ""}`} />
        <span class="card-list-title">{title}</span>
        {summary ? <span class={`card-list-summary${block.tone ? ` tone-${block.tone}` : ""}`}>{summary}</span> : null}
      </button>
      {open ? (
        <div role="list" aria-label={title}>
          {cardItems(block).filter((item) => cardText(item.title)).map((item, index) => (
            <ListRow key={typeof item.id === "string" ? item.id : index} item={item} />
          ))}
        </div>
      ) : null}
    </div>
  );
}

function ListRow(props: { item: RemoteCardItem; legend?: LegendState }): JSX.Element {
  const { item, legend } = props;
  const pinID = legend && typeof item.pinID === "string" ? item.pinID : undefined;
  const selected = !!pinID && legend?.selectedID === pinID;
  const title = cardText(item.title) ?? "";
  const subtitle = cardText(item.subtitle), detail = cardText(item.detail), note = cardText(item.note), trailing = cardText(item.trailing);
  const lead = symbolNode(item.symbol, item.glyph, legend ? 14 : 16);
  const actions = Array.isArray(item.actions) ? item.actions.filter((action) => action && typeof action === "object") : [];
  const choose = pinID ? () => legend!.select(pinID) : undefined;
  return (
    <div
      class={`card-row${pinID ? " selectable" : ""}${selected ? " selected" : ""}`}
      role="listitem"
      aria-label={itemLabel(item, "list")}
      aria-current={selected ? "true" : undefined}
      data-pin-id={pinID}
      tabIndex={pinID ? 0 : undefined}
      onClick={choose}
      onKeyDown={choose ? (event) => {
        if (event.target === event.currentTarget && (event.key === "Enter" || event.key === " ")) {
          event.preventDefault();
          choose();
        }
      } : undefined}
    >
      {lead ? <span class="card-row-symbol" aria-hidden="true">{lead}</span> : null}
      <div class="card-row-main">
        <div class="card-row-top">
          <span class="card-row-title">{title}</span>
          {trailing ? <span class="card-row-trailing">{trailing}</span> : null}
        </div>
        {subtitle ? <div class="card-row-subtitle">{subtitle}</div> : null}
        <Badges badges={item.badges} />
        {detail ? <div class="card-row-detail">{detail}</div> : null}
        {note ? <div class={`card-row-note${item.tone ? ` tone-${cardTone(item.tone)}` : ""}`}>{note}</div> : null}
        {actions.length ? <Actions actions={actions} context={title} /> : null}
      </div>
    </div>
  );
}

function Actions(props: { actions: RemoteCardAction[]; context: string }): JSX.Element | null {
  const buttons: JSX.Element[] = [], numbers: JSX.Element[] = [];
  props.actions.forEach((action, index) => {
    const label = cardText(action.label) ?? "Open";
    const icon = symbolIcon(actionSymbol(action.kind));
    const url = safeActionUrl(action);
    if (url) {
      buttons.push(
        <button key={index} type="button" class="card-action" aria-label={props.context ? `${label}, ${props.context}` : label}
          onClick={(event) => {
            event.stopPropagation();
            bridge.openExternal(url);
          }}>
          {icon ? <Icon name={icon} size={12} /> : null}
          {label}
        </button>,
      );
      return;
    }
    // This PC can't place a call: show the number instead of a button that does nothing.
    const phone = telNumber(action);
    if (phone) {
      numbers.push(
        <span key={index} class="card-action static selectable" aria-label={`Phone ${phone}`}>
          {icon ? <Icon name={icon} size={12} /> : null}
          {phone}
        </span>,
      );
    }
  });
  if (!buttons.length && !numbers.length) return null;
  return <div class="card-actions" onClick={(event) => event.stopPropagation()}>{buttons}{numbers}</div>;
}

function Badges(props: { badges: RemoteCardBadge[] | undefined }): JSX.Element | null {
  const badges = cardBadges(props.badges);
  if (!badges.length) return null;
  return (
    <div class="card-badges">
      {badges.map((badge, index) => (
        <span key={index} class={`card-badge tone-${cardTone(badge.tone)}`}>
          {symbolNode(badge.symbol, undefined, 12)}
          {cardText(badge.text)}
        </span>
      ))}
    </div>
  );
}

function NoticeBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const title = cardText(block.title), text = cardText(block.text);
  const icon = symbolNode(block.symbol, undefined, 16);
  return (
    <div class={`card-notice tone-${cardTone(block.tone)}`}>
      {title ? <div class="card-notice-title">{icon ? <span class="card-notice-symbol">{icon}</span> : null}{title}</div> : null}
      {text ? <div class="card-notice-text">{text}</div> : null}
    </div>
  );
}

/** A progress block (build cards): label and elapsed time, a bar, then where the estimate comes from.
 *  While it runs, a once-a-second timer redraws only this block. */
function ProgressBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const [now, setNow] = useState(() => Date.now());
  const state = progressState(block, now);
  useEffect(() => {
    if (!state.running) return undefined;
    const timer = window.setInterval(() => setNow(Date.now()), 1000);
    return () => window.clearInterval(timer);
  }, [state.running, block.startedAt]);
  const tone = state.running ? "accent" : cardTone(block.tone);
  return (
    <div class={`card-progress tone-${tone}`} role="group" aria-label={state.spoken}>
      <div class="card-progress-top">
        <span class="card-progress-label">{state.label}</span>
        {state.elapsed ? <span class="card-progress-time">{state.elapsed}</span> : null}
      </div>
      {state.showsBar ? (
        <div class={`card-progress-bar${state.fraction === undefined ? " indeterminate" : ""}`} aria-hidden="true">
          <span style={state.fraction === undefined ? undefined : { width: `${Math.max(2, state.fraction * 100)}%` }} />
        </div>
      ) : null}
      {state.detail || state.remaining ? (
        <div class="card-progress-foot">
          <span>{state.detail ?? ""}</span>
          {state.remaining ? <span class="card-progress-left">{state.remaining}</span> : null}
        </div>
      ) : null}
    </div>
  );
}

/** An image the Mac cached for a link preview (no other images are fetched). */
function CardImage(props: { block: RemoteCardBlock; hero?: boolean }): JSX.Element | null {
  const { block, hero } = props;
  const src = useLinkPreviewImage(typeof block.imageID === "string" ? block.imageID : undefined);
  if (!src) return null;
  const label = cardText(block.accessibilityLabel);
  const ratio = Number.isFinite(block.aspectRatio) && block.aspectRatio! > 0.2 && block.aspectRatio! < 5 ? block.aspectRatio : undefined;
  return (
    <div class={hero ? "link-preview-hero" : "card-image"} style={!hero && ratio ? { aspectRatio: String(ratio) } : undefined}>
      <img src={src} alt={hero ? "" : label ?? ""} />
    </div>
  );
}

/** A map block with, when the next block is its mapLinked list, that list as its legend. */
function MapBlock(props: { map: RemoteCardBlock; legend?: RemoteCardBlock }): JSX.Element {
  const { map, legend } = props;
  const pins = mapPins(map);
  const symbols = new Map(pins.map((pin) => [pin.id, pin]));
  const spec: MapSpec = {
    ...mapRegion(map),
    pins: pins.map((pin) => ({ id: pin.id, title: cardText(pin.title) ?? "", latitude: pin.latitude, longitude: pin.longitude })),
    attribution: mapAttribution(map.attribution),
    label: cardText(map.accessibilityLabel) ?? (pins.length === 1 ? `Map of ${cardText(pins[0].title) ?? "a place"}` : `Map of ${pins.length} places`),
  };
  const dot = (id: string): ComponentChildren => {
    const pin = symbols.get(id);
    return pin ? symbolNode(pin.symbol, pin.glyph, 12) : null;
  };
  return (
    <MapComposition
      map={spec}
      pinDot={(pin) => dot(pin.id)}
      legend={legend ? (state) => <ListBlock block={legend} legend={state} /> : undefined}
    />
  );
}

// MARK: Blocks views add (docs/views.md "New blocks in resolved cards")

/** A grouped-list heading that starts a group of the blocks after it. */
function SectionBlock(props: { block: RemoteCardBlock }): JSX.Element {
  const { block } = props;
  const title = cardText(block.title), subtitle = cardText(block.subtitle);
  const icon = symbolNode(block.symbol, undefined, 14);
  return (
    <div class="card-section">
      {title ? <div class="card-section-title" role="heading" aria-level={4}>{icon}{title}</div> : null}
      {subtitle ? <div class="card-section-subtitle">{subtitle}</div> : null}
    </div>
  );
}

/** A real table (column headers, a label per row) that scrolls sideways when it doesn't fit. */
function TableBlock(props: { block: RemoteCardBlock }): JSX.Element | null {
  const table = cardTable(props.block);
  if (!table) return null;
  const label = cardText(props.block.accessibilityLabel) ?? table.title;
  return (
    <>
      {table.title ? <div class="card-block-title">{table.title}</div> : null}
      <div class="card-table-scroll" role="region" aria-label={label ?? "Table"} tabIndex={0}>
        <table class="card-table">
          <thead>
            <tr>
              {table.columns.map((column, index) => (
                <th key={index} scope="col" class={`align-${column.align}`}>{column.title}</th>
              ))}
            </tr>
          </thead>
          <tbody>
            {table.rows.map((row) => (
              <tr key={row.key} aria-label={row.label}>
                {row.cells.map((cell, index) => (
                  <td key={index} class={`align-${table.columns[index].align}${cell.tone ? ` tone-${cell.tone}` : ""}`}>
                    {cell.symbol ? symbolNode(cell.symbol, undefined, 12) : null}
                    {cell.text}
                  </td>
                ))}
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </>
  );
}

/** A line through the points in order (accent blue, dots at each point) on its min…max scale, with the first,
 *  middle and last labels under it. Each point is focusable with its own label; the dots are HTML so they stay
 *  round while the line stretches to the card's width. */
function LineChartBlock(props: { block: RemoteCardBlock }): JSX.Element | null {
  const { block } = props;
  const chart = lineChart(block, 100, 100);
  if (!chart.points.length) return null;
  const title = cardText(block.title);
  const scaleText = (value: number) => value.toLocaleString(undefined, { maximumFractionDigits: 2 });
  const last = chart.points.length - 1;
  return (
    <>
      {title ? <div class="card-block-title">{title}</div> : null}
      <div class="card-linechart">
        <div class="card-linechart-scale" aria-hidden="true">
          <span>{scaleText(chart.max)}</span>
          <span>{scaleText(chart.min)}</span>
        </div>
        <div class="card-linechart-body">
          <div class="card-linechart-plot" role="group" aria-label={cardText(block.accessibilityLabel) ?? title ?? "Line chart"}>
            <svg class="card-linechart-svg" viewBox="0 0 100 100" preserveAspectRatio="none" aria-hidden="true">
              <line class="card-linechart-grid" x1="0" x2="100" y1="0" y2="0" vector-effect="non-scaling-stroke" />
              <line class="card-linechart-grid" x1="0" x2="100" y1="100" y2="100" vector-effect="non-scaling-stroke" />
              {last > 0 ? (
                <polyline class="card-linechart-path" points={chart.points.map((point) => `${point.x},${point.y}`).join(" ")}
                  vector-effect="non-scaling-stroke" />
              ) : null}
            </svg>
            {chart.points.map((point, index) => (
              <span key={index} class="card-linechart-dot" style={{ left: `${point.x}%`, top: `${point.y}%` }} tabIndex={0} role="img"
                aria-label={point.spoken} title={point.spoken} />
            ))}
          </div>
          <div class="card-linechart-labels" aria-hidden="true">
            {chart.labelled.map((index) => {
              const place = last > 0 && index === 0 ? "first" : last > 0 && index === last ? "last" : "middle";
              return (
                <span key={index} class={place} style={place === "middle" ? { left: `${chart.points[index].x}%` } : undefined}>
                  {chart.points[index].label}
                </span>
              );
            })}
          </div>
        </div>
      </div>
    </>
  );
}

const PIE_RADIUS = 15.915494309189533; // a circumference of 100

/** A donut of the items' shares with a legend: label, value and percentage. */
function PieChartBlock(props: { block: RemoteCardBlock }): JSX.Element | null {
  const { block } = props;
  const slices = pieSlices(block);
  if (!slices.length) return null;
  const title = cardText(block.title);
  return (
    <>
      {title ? <div class="card-block-title">{title}</div> : null}
      <div class="card-pie">
        <svg class="card-pie-svg" viewBox="0 0 42 42" aria-hidden="true">
          <circle class="card-pie-track" cx="21" cy="21" r={PIE_RADIUS} />
          {slices.filter((slice) => slice.fraction > 0).map((slice, index) => (
            <circle key={index} cx="21" cy="21" r={PIE_RADIUS} fill="none" stroke={slice.color} stroke-width="6"
              stroke-dasharray={`${slice.fraction * 100} ${100 - slice.fraction * 100}`}
              stroke-dashoffset={String(25 - slice.start * 100)} />
          ))}
        </svg>
        <ul class="card-pie-legend" aria-label={cardText(block.accessibilityLabel) ?? title ?? "Pie chart"}>
          {slices.map((slice, index) => (
            <li key={index} class="card-pie-row" aria-label={slice.spoken}>
              <span class="card-pie-swatch" style={{ background: slice.color }} aria-hidden="true" />
              <span class="card-pie-label">{slice.label}</span>
              <span class="card-pie-value">{slice.valueText}</span>
              <span class="card-pie-percent">{slice.percent}</span>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

/** The selected tab of each tabs block, by card and block, while the app runs (a refreshed card keeps it). */
const selectedTabs = signal<ReadonlyMap<string, number>>(new Map());

function domID(key: string): string {
  return `card-${key.replace(/[^A-Za-z0-9_-]/g, "_")}`;
}

/** A segmented tab bar (an ARIA tablist: arrows, Home and End move between tabs) over the selected tab's blocks. */
export function TabsBlock(props: {
  part: Extract<CardPart, { kind: "tabs" }>;
  stateKey: string;
  panel: (parts: CardPart[], key: string) => ComponentChildren;
}): JSX.Element {
  const { part, stateKey } = props;
  const count = part.tabs.length;
  const selected = Math.min(count - 1, Math.max(0, selectedTabs.value.get(stateKey) ?? 0));
  const base = domID(stateKey);
  const select = (index: number) => { selectedTabs.value = new Map(selectedTabs.value).set(stateKey, index); };
  const onKeyDown = (event: KeyboardEvent) => {
    const keys: Record<string, number> = { ArrowRight: selected + 1, ArrowLeft: selected - 1, Home: 0, End: count - 1 };
    if (!(event.key in keys)) return;
    event.preventDefault();
    const next = (keys[event.key] + count) % count;
    select(next);
    (event.currentTarget as HTMLElement | null)?.querySelectorAll<HTMLElement>("[role='tab']")[next]?.focus();
  };
  return (
    <div class="card-tabs">
      <div class="card-tabs-bar" role="tablist" aria-label={cardText(part.block.accessibilityLabel)} onKeyDown={onKeyDown}>
        {part.tabs.map((tab, index) => (
          <button key={index} type="button" role="tab" id={`${base}-tab-${index}`} class={`card-tab${index === selected ? " selected" : ""}`}
            aria-selected={index === selected} aria-controls={`${base}-panel-${index}`} tabIndex={index === selected ? 0 : -1}
            onClick={() => select(index)}>
            {symbolNode(tab.symbol, undefined, 14)}
            <span>{tab.title}</span>
          </button>
        ))}
      </div>
      {part.tabs.map((tab, index) => (
        <div key={index} role="tabpanel" id={`${base}-panel-${index}`} aria-labelledby={`${base}-tab-${index}`} class="card-tab-panel"
          hidden={index !== selected} tabIndex={0}>
          {index === selected ? props.panel(tab.parts, `${stateKey}/${index}`) : null}
        </div>
      ))}
    </div>
  );
}

/** View buttons waiting on their action, by card block and button. */
const runningActions = signal<ReadonlySet<string>>(new Set());

/**
 * Asks before running a view button (its confirmTitle and confirmMessage, the button's label to go ahead, Cancel)
 * and runs `onAction` only once the user confirms. Returns whether it ran.
 */
export async function confirmViewAction(button: CardButtonModel, onAction: CardActionHandler, key = button.id): Promise<boolean> {
  const confirmed = await confirmDialog({
    title: button.confirmTitle, message: button.confirmMessage, confirm: button.label, cancel: "Cancel",
  });
  if (!confirmed) return false;
  runningActions.value = new Set(runningActions.value).add(key);
  try {
    await onAction(button);
  } finally {
    const next = new Set(runningActions.value);
    next.delete(key);
    runningActions.value = next;
  }
  return true;
}

/** A view's buttons in a wrapping row; each asks first. Kinds this client doesn't run are hidden. */
export function ActionsBlock(props: { block: RemoteCardBlock; onAction: CardActionHandler; kinds: ReadonlySet<string>; stateKey: string }): JSX.Element | null {
  const buttons = cardButtons(props.block, props.kinds);
  if (!buttons.length) return null;
  return (
    <div class="card-view-actions" role="group" aria-label={cardText(props.block.accessibilityLabel) ?? "Actions"}>
      {buttons.map((button) => {
        const key = `${props.stateKey}:${button.id}`;
        const icon = symbolIcon(button.symbol) ?? symbolIcon(buttonSymbol(button.kind));
        return (
          <button key={button.id} type="button" class={`card-view-action${button.prominent ? " prominent" : ""}`} aria-haspopup="dialog"
            disabled={runningActions.value.has(key)} data-kind={button.kind}
            onClick={() => void confirmViewAction(button, props.onAction, key).catch(() => {})}>
            {icon ? <Icon name={icon} size={14} /> : null}
            <span>{button.label}</span>
          </button>
        );
      })}
    </div>
  );
}
