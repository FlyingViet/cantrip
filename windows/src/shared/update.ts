export function sanitizeUpdateError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  if (/\b404\b/.test(raw)) {
    return "the GitHub release feed has not been published yet.";
  }
  const firstLine = raw.split(/\r?\n/, 1)[0].trim();
  return (firstLine || "unknown updater error").slice(0, 180);
}

/** Windows releases share FlyingViet/cantrip with the Mac host's `v*` releases, so they use
 * their own tags and the updater looks them up itself (the repository's "Latest" is the host). */
export const WINDOWS_RELEASE_TAG_PREFIX = "windows-v";
export const WINDOWS_RELEASES_API =
  "https://api.github.com/repos/FlyingViet/cantrip/releases?per_page=50";
const RELEASE_DOWNLOAD_BASE = "https://github.com/FlyingViet/cantrip/releases/download/";

type ReleaseSummary = { tag_name?: unknown; draft?: unknown; prerelease?: unknown };

function windowsVersion(tag: string): number[] | null {
  const match = /^windows-v(\d+)\.(\d+)\.(\d+)$/.exec(tag);
  return match ? match.slice(1).map(Number) : null;
}

function compareVersions(a: number[], b: number[]): number {
  for (let index = 0; index < 3; index += 1) {
    if (a[index] !== b[index]) return a[index] - b[index];
  }
  return 0;
}

/** The newest published, non-prerelease `windows-vX.Y.Z` tag, or null when there is none. */
export function latestWindowsReleaseTag(releases: unknown): string | null {
  if (!Array.isArray(releases)) return null;
  let best: { tag: string; version: number[] } | null = null;
  for (const release of releases as ReleaseSummary[]) {
    if (!release || release.draft === true || release.prerelease === true) continue;
    if (typeof release.tag_name !== "string") continue;
    const version = windowsVersion(release.tag_name);
    if (!version) continue;
    if (!best || compareVersions(version, best.version) > 0) best = { tag: release.tag_name, version };
  }
  return best?.tag ?? null;
}

/** The generic update feed for a release: its `latest.yml` and installer sit under this URL. */
export function windowsReleaseFeedURL(tag: string): string {
  return RELEASE_DOWNLOAD_BASE + encodeURIComponent(tag);
}
