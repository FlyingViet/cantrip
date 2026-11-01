import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { cachedImage, loadLinkPreviewImage, loadMapTile } from "../../api/client";
import type { RemoteLinkPreview, RemotePlaceCard, RemotePlacePin, RemoteWeatherCard } from "../../api/types";
import { Icon, type IconName } from "../icons";
import { bridge } from "../../bridge";
import {
  initialZoomForDelta, isSafePublicUrl, latToTileY, lonToTileX, placeDirectionsUrl, placeGlyph, placeNote, pinOffsets, pinWidth,
  weatherAttributionUrl, weatherChance, weatherDetail, weatherIcon, weatherRanges, weatherSpoken, weatherTint, weatherUnitName,
} from "./richCardLogic";

function WeatherGlyph(props: { symbol: string | undefined; size?: 16 | 18 | 28 }): JSX.Element {
  return <span class={`weather-glyph ${weatherTint(props.symbol)}`}><Icon name={weatherIcon(props.symbol) as IconName} size={props.size ?? 18} /></span>;
}

/** A reply's forecast card: Open-Meteo numbers the Mac fetched, in the map card's container. */
export function WeatherCardView(props: { card: RemoteWeatherCard | undefined }): JSX.Element | null {
  const card = props.card;
  if (!card || typeof card !== "object") return null;
  const current = card.status === "ok" ? card.current : undefined;
  const hourly = (card.hourly ?? []).slice(0, 13), daily = (card.daily ?? []).slice(0, 10);
  const ranges = weatherRanges(daily);
  const updated = current && card.updatedAt ? new Date(card.updatedAt) : null;
  const detail = weatherDetail(card);
  return (
    <section class="weather-card" aria-label={`Weather for ${card.place || "this place"}`}>
      <div class="weather-head">
        <div class="weather-info">
          <div class="weather-place">{card.place || "Weather"}</div>
          {card.placeNote ? <div class="weather-note"><Icon name="location.fill" size={12} />{card.placeNote}</div> : null}
          {current ? (
            <>
              <div class="weather-cond">{current.condition}</div>
              {detail ? <div class="weather-detail">{detail}</div> : null}
            </>
          ) : (
            <>
              <div class="weather-unavailable"><Icon name="exclamationmark.icloud" size={16} />Forecast unavailable</div>
              <div class="weather-reason">{card.message || "Ask again in a moment."}</div>
            </>
          )}
        </div>
        {current ? (
          <div class="weather-now" role="img" aria-label={`Now ${Math.round(current.temperature)} ${weatherUnitName(card.unit)}, ${current.condition}`}>
            <WeatherGlyph symbol={current.symbol} size={28} />
            <span class="weather-now-temp">{Math.round(current.temperature)}°</span>
          </div>
        ) : null}
      </div>
      {current && hourly.length ? (
        <div class="weather-hours" role="list" aria-label="Hourly forecast">
          {hourly.map((hour, index) => (
            <div key={index} class="weather-hour" role="listitem"
              aria-label={weatherSpoken(hour.label, String(Math.round(hour.temperature)), card.unit, hour.condition, hour.precipitationChance)}>
              <span class="weather-hour-label">{hour.label}</span>
              <WeatherGlyph symbol={hour.symbol} />
              <span class="weather-chance">{weatherChance(hour.precipitationChance)}</span>
              <span class="weather-hour-temp">{Math.round(hour.temperature)}°</span>
            </div>
          ))}
        </div>
      ) : null}
      {current && daily.length ? (
        <div class="weather-days" role="list" aria-label={`${daily.length}-day forecast`}>
          {daily.map((day, index) => (
            <div key={day.date || index} class="weather-day" role="listitem"
              aria-label={`${day.label}, ${day.condition}, high ${Math.round(day.high)}, low ${Math.round(day.low)} ${weatherUnitName(card.unit)}${weatherChance(day.precipitationChance) ? `, ${Math.round(day.precipitationChance ?? 0)} percent chance of precipitation` : ""}`}>
              <span class="weather-day-label">{day.label}</span>
              <WeatherGlyph symbol={day.symbol} size={16} />
              <span class="weather-chance">{weatherChance(day.precipitationChance)}</span>
              <span class="weather-low">{Math.round(day.low)}°</span>
              <span class="weather-bar" aria-hidden="true"><span style={{ left: `${ranges[index].left}%`, width: `${ranges[index].width}%` }} /></span>
              <span class="weather-high">{Math.round(day.high)}°</span>
            </div>
          ))}
        </div>
      ) : null}
      <div class="weather-foot">
        {updated && !Number.isNaN(updated.getTime()) ? <span>Updated {updated.toLocaleTimeString([], { hour: "numeric", minute: "2-digit" })}</span> : null}
        <button type="button" class="weather-attr" onClick={() => bridge.openExternal(weatherAttributionUrl(card.attributionURL))}>
          {card.attribution || "Weather data by Open-Meteo.com"}
        </button>
      </div>
    </section>
  );
}

export function LinkPreviewStack(props: { cards: RemoteLinkPreview[] | undefined }): JSX.Element | null {
  const cards = (props.cards ?? []).filter((c) => isSafePublicUrl(c.url));
  if (!cards.length) return null;
  return (
    <div class="link-preview-stack">
      {cards.map((card) => (
        <LinkPreviewCard key={card.id} card={card} />
      ))}
    </div>
  );
}

function LinkPreviewCard(props: { card: RemoteLinkPreview }): JSX.Element {
  const { card } = props;
  const cacheKey = card.imageID ? `link-preview:${card.imageID}` : "";
  const [heroSrc, setHeroSrc] = useState<string | null>(cacheKey ? cachedImage(cacheKey) ?? null : null);

  useEffect(() => {
    if (!card.imageID) {
      setHeroSrc(null);
      return;
    }
    let live = true;
    void loadLinkPreviewImage(card.imageID).then(
      (url) => {
        if (live) setHeroSrc(url);
      },
      () => {
        if (live) setHeroSrc(null);
      },
    );
    return () => {
      live = false;
    };
  }, [card.imageID]);

  return (
    <button
      type="button"
      class="link-preview-card"
      role="link"
      aria-label={`${card.title}, ${card.domain}`}
      onClick={() => bridge.openExternal(card.url)}
    >
      {heroSrc ? (
        <div class="link-preview-hero">
          <img src={heroSrc} alt="" />
        </div>
      ) : null}
      <div class="link-preview-meta">
        <div class="link-preview-title">{card.title}</div>
        <div class="link-preview-domain">{card.domain}</div>
      </div>
    </button>
  );
}

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

export function PlaceCardView(props: { card: RemotePlaceCard | undefined }): JSX.Element | null {
  const card = props.card;
  if (!card || !Array.isArray(card.places) || !card.places.length) return null;

  const [zoom, setZoom] = useState<number>(() =>
    initialZoomForDelta(Math.max(card.latitudeDelta || 0.04, card.longitudeDelta || 0.04)),
  );
  const [center, setCenter] = useState<{ lat: number; lon: number }>({
    lat: card.centerLatitude,
    lon: card.centerLongitude,
  });
  const [selectedID, setSelectedID] = useState<string>(card.places[0].id);

  const mapW = 580;
  const mapH = 310;
  const centerTX = lonToTileX(center.lon, zoom);
  const centerTY = latToTileY(center.lat, zoom);
  const baseTX = Math.floor(centerTX);
  const baseTY = Math.floor(centerTY);
  const offsetX = mapW / 2 - (centerTX - baseTX) * 256;
  const offsetY = mapH / 2 - (centerTY - baseTY) * 256;

  const tiles: { dx: number; dy: number; tx: number; ty: number; left: number; top: number }[] = [];
  for (let dy = -1; dy <= 1; dy++) {
    for (let dx = -2; dx <= 2; dx++) {
      tiles.push({
        dx,
        dy,
        tx: baseTX + dx,
        ty: baseTY + dy,
        left: Math.round(offsetX + dx * 256),
        top: Math.round(offsetY + dy * 256),
      });
    }
  }

  // Close places: later pins move to the nearest free spot so every name stays readable.
  const points = card.places.map((place) => ({
    x: mapW / 2 + (lonToTileX(place.longitude, zoom) - centerTX) * 256,
    y: mapH / 2 + (latToTileY(place.latitude, zoom) - centerTY) * 256,
  }));
  const moves = pinOffsets(points.map((point, index) => ({ ...point, w: pinWidth(card.places[index].name), h: 24 })), mapW, mapH);

  return (
    <section class="place-card" aria-label={card.query || "Recommended places"}>
      <div class="place-map-surface">
        {tiles.map((t) => (
          <MapTileImg key={`${zoom}:${t.tx}:${t.ty}`} z={zoom} x={t.tx} y={t.ty} left={t.left} top={t.top} />
        ))}
        {card.places.map((place, index) => {
          const px = points[index].x;
          const py = points[index].y;
          const [moveX, moveY] = moves[index];
          return (
            <button
              key={place.id}
              type="button"
              class={`place-pin${selectedID === place.id ? " active" : ""}`}
              style={{
                left: `${Math.round(px)}px`, top: `${Math.round(py)}px`,
                ...(moveX || moveY ? { transform: `translate(calc(-50% + ${moveX}px), calc(-50% + ${moveY}px))` } : {}),
              }}
              onClick={() => {
                setSelectedID(place.id);
                bridge.openExternal(placeDirectionsUrl(place));
              }}
            >
              <span class="place-pin-dot" aria-hidden="true">{placeGlyph(place)}</span>
              <span class="place-pin-label">{place.name}</span>
            </button>
          );
        })}
      </div>

      <div class="place-list-overlay">
        {card.places.map((place) => {
          const metaParts: string[] = [];
          if (typeof place.rating === "number") {
            metaParts.push(
              `${place.rating.toFixed(1)} ★${typeof place.reviewCount === "number" ? ` (${place.reviewCount})` : ""}`,
            );
          }
          if (place.priceLevel) metaParts.push(place.priceLevel);
          if (place.category) metaParts.push(place.category);
          const cleanPhone = place.phone ? place.phone.replace(/[^0-9+]/g, "") : "";
          return (
            <div
              key={place.id}
              class={`place-row${selectedID === place.id ? " selected" : ""}`}
              onClick={() => {
                setSelectedID(place.id);
                setCenter({ lat: place.latitude, lon: place.longitude });
              }}
            >
              <div class="place-row-name">{place.name}</div>
              {metaParts.length ? <div class="place-row-meta">{metaParts.join(" · ")}</div> : null}
              {typeof place.isOpenNow === "boolean" ? (
                <div class={`place-row-status ${place.isOpenNow ? "open" : "closed"}`}>
                  {place.isOpenNow ? "Open" : "Closed"}
                </div>
              ) : place.address ? (
                <div class="place-row-meta">{place.address}</div>
              ) : null}
              {(() => {
                const note = placeNote(place);
                return note ? <div class={`place-row-meta${note.warning ? " place-row-warning" : ""}`}>{note.text}</div> : null;
              })()}
              <div class="place-row-actions" onClick={(e) => e.stopPropagation()}>
                <button
                  type="button"
                  class="place-action-link"
                  onClick={() => bridge.openExternal(placeDirectionsUrl(place))}
                >
                  Directions
                </button>
                {cleanPhone ? (
                  <button type="button" class="place-action-link" onClick={() => bridge.openExternal(`tel:${cleanPhone}`)}>
                    Call
                  </button>
                ) : null}
                {place.website && isSafePublicUrl(place.website) ? (
                  <button type="button" class="place-action-link" onClick={() => bridge.openExternal(place.website!)}>
                    Website
                  </button>
                ) : null}
              </div>
            </div>
          );
        })}
      </div>

      <div class="place-zoom-controls">
        <button type="button" aria-label="Zoom in" onClick={() => setZoom((z) => Math.min(18, z + 1))}>
          +
        </button>
        <button type="button" aria-label="Zoom out" onClick={() => setZoom((z) => Math.max(3, z - 1))}>
          −
        </button>
      </div>

      <div class="place-attribution">© OpenStreetMap · Apple Maps</div>
    </section>
  );
}
