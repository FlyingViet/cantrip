// Generic cards (`RemoteMessage.cards`, docs/cards.md): one component per block, so a new kind of card
// needs no code here. Panel cards share the weather card's container; `link` cards look like link
// previews. Strings are only ever drawn as text, and actions open public http(s) pages only.
import type { ComponentChildren, JSX } from "preact";
import type { RemoteCardAction, RemoteCardBadge, RemoteCardBlock, RemoteCardDocument, RemoteCardItem } from "../../api/types";
import { bridge } from "../../bridge";
import { Icon, symbolIcon } from "../icons";
import { MapComposition, type LegendState, type MapSpec } from "./CardMap";
import {
  actionSymbol, cardBadges, cardFallback, cardFooter, cardGlyph, cardItems, cardLabel, cardLines, cardParts, cardRows, cardStyle, cardText,
  cardTone, chartBar, chartColumns, chartScale, itemLabel, mapAttribution, mapPins, mapRegion, safeActionUrl, statLabel, telNumber,
  type CardPart,
} from "./cardLogic";
import { useLinkPreviewImage } from "./RichCards";
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

export function CardView(props: { card: RemoteCardDocument }): JSX.Element | null {
  const { card } = props;
  const parts = cardParts(card);
  if (!parts.length) {
    const fallback = cardFallback(card);
    return fallback ? <div class="card-fallback selectable">{fallback}</div> : null;
  }
  return cardStyle(card) === "link" ? <LinkCard card={card} parts={parts} /> : <PanelCard card={card} parts={parts} />;
}

const FLOW_BLOCKS = new Set(["header", "stat", "notice", "badges"]);

function PanelCard(props: { card: RemoteCardDocument; parts: CardPart[] }): JSX.Element {
  const { card, parts } = props;
  const footer = cardFooter(card.source);
  return (
    <section class="card-panel" aria-label={cardLabel(card)}>
      {parts.map((part, index) => {
        if (part.kind === "map") {
          return (
            <div key={index} class={`card-block card-map${part.divided ? " card-divided" : ""}`}>
              <MapBlock map={part.map} legend={part.legend} />
            </div>
          );
        }
        const flow = FLOW_BLOCKS.has(part.block.type);
        return (
          <div key={index} class={`card-block card-${part.block.type}-block${flow ? " card-flow" : ""}${part.divided ? " card-divided" : ""}`}>
            <BlockView block={part.block} />
          </div>
        );
      })}
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
        {cardText(block.subtitle) ? <div class="link-preview-domain">{cardText(block.subtitle)}</div> : null}
        {lines.map((line, index) => <div key={index} class="link-preview-domain">{line}</div>)}
      </div>
    </div>
  );
}

function BlockView(props: { block: RemoteCardBlock }): JSX.Element | null {
  const { block } = props;
  switch (block.type) {
    case "header": return <HeaderBlock block={block} />;
    case "stat": return <StatBlock block={block} />;
    case "keyValue": return <KeyValueBlock block={block} />;
    case "strip": return <StripBlock block={block} />;
    case "chart": return <ChartBlock block={block} />;
    case "list": return <ListBlock block={block} />;
    case "image": return <CardImage block={block} />;
    case "badges": return <Badges badges={block.badges} />;
    case "notice": return <NoticeBlock block={block} />;
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
      {lead ? <span class="card-head-symbol" aria-hidden="true">{lead}</span> : null}
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
  return (
    <div class="card-chart" role="list" aria-label={cardText(block.accessibilityLabel)}>
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
