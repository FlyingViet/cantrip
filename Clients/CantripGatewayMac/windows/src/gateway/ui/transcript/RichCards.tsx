import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import { cachedImage, loadLinkPreviewImage, loadMapTile } from "../../api/client";
import type { RemoteLinkPreview, RemotePlaceCard, RemotePlacePin } from "../../api/types";
import { bridge } from "../../bridge";
import { initialZoomForDelta, isSafePublicUrl, latToTileY, lonToTileX, placeDirectionsUrl, placeGlyph, placeNote, pinOffsets, pinWidth } from "./richCardLogic";

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
