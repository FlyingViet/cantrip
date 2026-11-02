// The interactive map shared by the generic `map` block (Cards.tsx) and older Macs' place cards
// (RichCards.tsx): OpenStreetMap tiles through the Mac, labeled pins, zoom buttons, the attribution and an
// optional legend that floats over the map when the card is wide and sits under it when it's narrow.
import type { ComponentChildren, JSX } from "preact";
import { useEffect, useLayoutEffect, useRef, useState } from "preact/hooks";
import { cachedImage, loadMapTile } from "../../api/client";
import { fitZoom, initialZoomForDelta, latToTileY, lonToTileX, pinOffsets, pinWidth, tileSpan } from "./richCardLogic";

export interface MapPinSpec {
  id: string;
  title: string;
  latitude: number;
  longitude: number;
}

export interface MapSpec {
  latitude: number;
  longitude: number;
  latitudeDelta: number;
  longitudeDelta: number;
  pins: MapPinSpec[];
  attribution: string;
  /** The map's name for screen readers ("Map of 3 places"). */
  label: string;
}

/** Narrower cards put the legend under the map (the Mac floats it from 600 pt; this card tops out at 580 px). */
export const LEGEND_FLOAT_MIN_WIDTH = 520;
const LEGEND_INSET = 12;
const LEGEND_WIDTH = 248;
const DEFAULT_WIDTH = 580;

function MapTileImg(props: { z: number; x: number; y: number; left: number; top: number }): JSX.Element | null {
  const { z, x, y, left, top } = props;
  const maxTile = 1 << z;
  const wrappedX = ((x % maxTile) + maxTile) % maxTile;
  const validY = y >= 0 && y < maxTile;
  const cacheKey = `map-tile:${z}/${wrappedX}/${y}`;
  const [src, setSrc] = useState<string | null>(validY ? cachedImage(cacheKey) ?? null : null);

  useEffect(() => {
    if (!validY) {
      setSrc(null);
      return;
    }
    let live = true;
    void loadMapTile(z, wrappedX, y).then(
      (url) => {
        if (live) setSrc(url);
      },
      () => {
        if (live) setSrc(null);
      },
    );
    return () => {
      live = false;
    };
  }, [z, wrappedX, y, validY]);

  if (!src) return null;
  return <img class="place-map-tile" src={src} alt="" style={{ left: `${left}px`, top: `${top}px` }} />;
}

export interface LegendState {
  selectedID: string;
  /** A row was chosen: select its pin and center the map on it. */
  select: (id: string) => void;
  floating: boolean;
}

export function MapComposition(props: {
  map: MapSpec;
  /** What a pin's dot shows (an icon or emoji). */
  pinDot: (pin: MapPinSpec) => ComponentChildren;
  /** The map's legend; rows carry `data-pin-id` so choosing a pin can scroll its row into view. */
  legend?: (state: LegendState) => ComponentChildren;
  /** After a pin is chosen (older Macs' cards open its directions). */
  onPinClick?: (pin: MapPinSpec) => void;
}): JSX.Element {
  const { map } = props;
  const root = useRef<HTMLDivElement>(null);
  const legendBox = useRef<HTMLDivElement>(null);
  const [width, setWidth] = useState(DEFAULT_WIDTH);
  const [userZoom, setUserZoom] = useState<number | null>(null);
  const [center, setCenter] = useState<{ lat: number; lon: number }>({ lat: map.latitude, lon: map.longitude });
  const [selectedID, setSelectedID] = useState<string>(map.pins[0]?.id ?? "");

  useLayoutEffect(() => {
    const node = root.current;
    if (!node || typeof ResizeObserver === "undefined") return;
    const measure = () => setWidth(Math.round(node.clientWidth) || DEFAULT_WIDTH);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(node);
    return () => observer.disconnect();
  }, []);

  const hasLegend = !!props.legend;
  const floating = hasLegend && width >= LEGEND_FLOAT_MIN_WIDTH;
  const mapW = width;
  const mapH = hasLegend && !floating ? 240 : 310;
  // The part of the map the floating legend doesn't cover; the map centers there.
  const visibleLeft = floating ? LEGEND_INSET + LEGEND_WIDTH + 8 : 0;
  const visibleW = Math.max(120, mapW - visibleLeft);
  const focalX = visibleLeft + visibleW / 2;
  const focalY = mapH / 2;
  const startZoom = initialZoomForDelta(Math.max(map.latitudeDelta || 0.04, map.longitudeDelta || 0.04));
  const fitted = fitZoom(
    map.pins.map((pin) => ({ latitude: pin.latitude, longitude: pin.longitude, w: pinWidth(pin.title) })),
    { lat: map.latitude, lon: map.longitude }, startZoom, { width: visibleW, height: mapH },
  );
  const zoom = userZoom ?? fitted;

  const centerTX = lonToTileX(center.lon, zoom);
  const centerTY = latToTileY(center.lat, zoom);
  const baseTX = Math.floor(centerTX);
  const baseTY = Math.floor(centerTY);
  const offsetX = focalX - (centerTX - baseTX) * 256;
  const offsetY = focalY - (centerTY - baseTY) * 256;
  const [firstX, lastX] = tileSpan(offsetX, mapW);
  const [firstY, lastY] = tileSpan(offsetY, mapH);
  const tiles: { tx: number; ty: number; left: number; top: number }[] = [];
  for (let dy = firstY; dy <= lastY; dy++) {
    for (let dx = firstX; dx <= lastX; dx++) {
      tiles.push({ tx: baseTX + dx, ty: baseTY + dy, left: Math.round(offsetX + dx * 256), top: Math.round(offsetY + dy * 256) });
    }
  }

  // Close places: later pins move to the nearest free spot so every name stays readable.
  const points = map.pins.map((pin) => ({
    x: focalX + (lonToTileX(pin.longitude, zoom) - centerTX) * 256,
    y: focalY + (latToTileY(pin.latitude, zoom) - centerTY) * 256,
  }));
  const moves = pinOffsets(
    points.map((point, index) => ({ x: point.x - visibleLeft, y: point.y, w: pinWidth(map.pins[index].title), h: 24 })),
    visibleW, mapH,
  );

  const revealRow = (id: string) => {
    const box = legendBox.current;
    if (!floating || !box) return;
    const row = [...box.querySelectorAll<HTMLElement>("[data-pin-id]")].find((node) => node.dataset.pinId === id);
    if (!row) return;
    if (row.offsetTop < box.scrollTop) box.scrollTop = row.offsetTop;
    else if (row.offsetTop + row.offsetHeight > box.scrollTop + box.clientHeight) box.scrollTop = row.offsetTop + row.offsetHeight - box.clientHeight;
  };
  const select = (id: string) => {
    const pin = map.pins.find((candidate) => candidate.id === id);
    setSelectedID(id);
    if (pin) setCenter({ lat: pin.latitude, lon: pin.longitude });
  };

  return (
    <div ref={root} class={`map-composition${floating ? " floating" : hasLegend ? " stacked" : ""}`}>
      <div class="place-map" role="group" aria-label={map.label} style={{ height: `${mapH}px` }}>
        {tiles.map((t) => (
          <MapTileImg key={`${zoom}:${t.tx}:${t.ty}`} z={zoom} x={t.tx} y={t.ty} left={t.left} top={t.top} />
        ))}
        {map.pins.map((pin, index) => {
          const [moveX, moveY] = moves[index];
          return (
            <button
              key={pin.id}
              type="button"
              class={`place-pin${selectedID === pin.id ? " active" : ""}`}
              aria-pressed={selectedID === pin.id}
              style={{
                left: `${Math.round(points[index].x)}px`, top: `${Math.round(points[index].y)}px`,
                ...(moveX || moveY ? { transform: `translate(calc(-50% + ${moveX}px), calc(-50% + ${moveY}px))` } : {}),
              }}
              onClick={() => {
                setSelectedID(pin.id);
                revealRow(pin.id);
                props.onPinClick?.(pin);
              }}
            >
              <span class="place-pin-dot" aria-hidden="true">{props.pinDot(pin)}</span>
              <span class="place-pin-label">{pin.title}</span>
            </button>
          );
        })}
        <div class="place-zoom-controls">
          <button type="button" aria-label="Zoom in" onClick={() => setUserZoom(Math.min(18, zoom + 1))}>
            +
          </button>
          <button type="button" aria-label="Zoom out" onClick={() => setUserZoom(Math.max(3, zoom - 1))}>
            −
          </button>
        </div>
        <div class="place-attribution">{map.attribution}</div>
      </div>
      {props.legend ? (
        <div ref={legendBox} class="place-list-overlay">
          {props.legend({ selectedID, select, floating })}
        </div>
      ) : null}
    </div>
  );
}
