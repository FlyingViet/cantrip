// Home's Artifacts (CantripHomeArtifactsView): files Cantrip Home saved on the Mac, as a grid of cards. Images open
// in the viewer; other files download through a Save dialog (Windows has no Quick Look).
import { signal } from "@preact/signals";
import type { JSX } from "preact";
import { useEffect, useState } from "preact/hooks";
import type { HomeArtifact } from "../../api/types";
import * as nav from "../../state/nav";
import * as remote from "../../state/remote";
import { Icon } from "../icons";
import { alertDialog, confirmDialog, MenuButton, Spinner, type MenuEntry } from "../kit";
import { openViewer } from "../viewer";
import {
  artifactAccessibilityText, artifactFileName, artifactGlyph, capitalized, durationLabel, fileSize, isImageArtifact,
  isVideoArtifact, supportsThumbnail, artifactKey,
} from "./homeLogic";
import { deleteArtifact, homeDataError } from "./homeState";
import { contextMenuAt, ErrorLine, HomeGate, Unavailable } from "./parts";
import { ArtifactTypeGlyph } from "./symbols";
import {
  artifactBlob, cachedThumbnail, isThumbnailUnavailable, loadArtifactData, loadArtifactImage, loadThumbnail,
  resetThumbnailFailures, type Thumbnail,
} from "./thumbnails";

/** The artifact being fetched to open or save; every card waits for it. */
const loadingID = signal<string | null>(null);
const status = signal("");

export function ArtifactsView(): JSX.Element {
  useEffect(() => {
    status.value = "";
    // Windows has no pull-to-refresh, so opening Artifacts is when failed thumbnails get another try.
    resetThumbnailFailures();
    void remote.refreshHomeData();
  }, []);
  return <HomeGate>{() => <ArtifactGrid />}</HomeGate>;
}

function ArtifactGrid(): JSX.Element {
  const snapshot = remote.homeArtifacts.value;
  const artifacts = snapshot?.artifacts ?? [];
  const loading = snapshot === null && remote.homeArtifactsError.value === null;
  const error = homeDataError.value;
  if (!artifacts.length) {
    if (loading) return <div class="hm-root"><div class="hm-unavailable" role="status"><Spinner size="large" label="Loading artifacts" /></div></div>;
    return (
      <div class="hm-root">
        <Unavailable icon={<Icon name="square.grid.2x2" size={56} />} title="No artifacts yet" error={error}
          description="Documents and media created in Cantrip Home are collected here automatically."
          action={<button type="button" class="btn primary large" onClick={() => nav.openChat("Create a ")}>Create in Chat</button>} />
      </div>
    );
  }
  return (
    <div class="hm-root">
      <div class="hm-scroll">
        <ErrorLine text={error} class="hm-error-banner" />
        <ul class="ha-grid" aria-label="Artifacts">
          {artifacts.map((artifact) => <ArtifactCard key={artifact.id} artifact={artifact} />)}
        </ul>
        <div class="sr-only" role="status" aria-live="polite">{status.value}</div>
      </div>
    </div>
  );
}

function confirmDelete(artifact: HomeArtifact): void {
  void confirmDialog({
    title: `Delete ${artifact.title || "artifact"}?`, message: "This permanently deletes the file from your Mac.",
    confirm: "Delete artifact", destructive: true,
  }).then(async (confirmed) => {
    if (confirmed && (await deleteArtifact(artifact))) status.value = `Deleted ${artifact.title}.`;
  });
}

/** Downloads the file; Windows asks where to save it. */
async function save(artifact: HomeArtifact): Promise<void> {
  if (loadingID.value) return;
  loadingID.value = artifact.id;
  status.value = `Downloading ${artifact.title}…`;
  try {
    const { data, mimeType } = await loadArtifactData(artifact);
    const url = URL.createObjectURL(artifactBlob(data, mimeType));
    const link = document.createElement("a");
    link.href = url;
    link.download = artifactFileName(artifact);
    document.body.append(link);
    link.click();
    link.remove();
    setTimeout(() => URL.revokeObjectURL(url), 60000);
    status.value = `Downloaded ${artifact.title}.`;
  } catch (error) {
    status.value = "";
    void alertDialog("Could not open artifact", (error as Error).message);
  } finally {
    loadingID.value = null;
  }
}

/** Images open in the viewer; everything else downloads (the Mac opens Quick Look). */
function open(artifact: HomeArtifact): void {
  if (loadingID.value) return;
  if (isImageArtifact(artifact)) {
    openViewer({ title: artifact.title, placeholder: cachedThumbnail(artifact)?.src, load: () => loadArtifactImage(artifact) });
    return;
  }
  void save(artifact);
}

function ArtifactCard(props: { artifact: HomeArtifact }): JSX.Element {
  const { artifact } = props;
  const [thumbnail, setThumbnail] = useState<Thumbnail | null>(() => cachedThumbnail(artifact));
  const [loading, setLoading] = useState(() => !thumbnail && supportsThumbnail(artifact) && !isThumbnailUnavailable(artifact));
  const key = artifactKey(artifact);
  useEffect(() => {
    const cached = cachedThumbnail(artifact);
    setThumbnail(cached);
    if (cached || !supportsThumbnail(artifact) || isThumbnailUnavailable(artifact)) {
      setLoading(false);
      return;
    }
    let live = true;
    setLoading(true);
    void loadThumbnail(artifact).then((loaded) => {
      if (!live) return;
      setThumbnail(loaded);
      setLoading(false);
    });
    return () => { live = false; };
  }, [key]);

  const busy = loadingID.value !== null;
  const opening = loadingID.value === artifact.id;
  const image = isImageArtifact(artifact);
  const entries = (): MenuEntry[] => [
    ...(image ? [{ label: "Open", icon: "photo", disabled: busy, onSelect: () => open(artifact) } as MenuEntry] : []),
    { label: "Save As…", icon: "arrow.down.circle", disabled: busy, onSelect: () => void save(artifact) },
    { kind: "separator" },
    { label: "Delete", icon: "trash", destructive: true, disabled: busy || remote.isMutating.value, onSelect: () => confirmDelete(artifact) },
  ];
  const duration = thumbnail?.durationSeconds;
  return (
    <li class="ha-item" onContextMenu={(event) => contextMenuAt(event, entries(), `${artifact.title} actions`)}>
      <button type="button" class="ha-card" disabled={busy} aria-busy={opening ? "true" : undefined}
        aria-label={artifactAccessibilityText(artifact, duration)} title={image ? "Opens the image" : "Downloads the file"}
        onClick={() => open(artifact)}>
        <span class="ha-thumb" aria-hidden="true">
          {thumbnail ? <img src={thumbnail.src} alt="" draggable={false} /> : <span class="ha-type"><ArtifactTypeGlyph name={artifactGlyph(artifact)} size={34} /></span>}
          {thumbnail && isVideoArtifact(artifact) ? <span class="ha-play"><svg viewBox="0 0 24 24" width="17" height="17"><path d="M8 5.5v13l10.5-6.5z" fill="#fff" /></svg></span> : null}
          {duration !== undefined ? <span class="ha-duration">{durationLabel(duration)}</span> : loading ? <span class="ha-loading"><Spinner size="small" /></span> : null}
          {opening ? <span class="ha-opening"><Spinner /></span> : null}
        </span>
        <span class="ha-title">{artifact.title}</span>
        <span class="ha-meta"><span>{capitalized(artifact.kind)}</span><span>{fileSize(artifact.size)}</span></span>
      </button>
      <MenuButton class="ha-menu" label={`Actions for ${artifact.title}`} entries={entries} disabled={busy}>
        <Icon name="ellipsis" size={14} />
        <Icon name="chevron.down" size={12} />
      </MenuButton>
    </li>
  );
}
