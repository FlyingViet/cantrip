// Pure helpers for BrowserPreview.tsx (no window bridge), so tests can import them.

/** True when any tool call in the reply came from the Mac's browser MCP server (`activity.browser`). */
export function usesBrowser(activities: { browser?: boolean }[] | undefined): boolean {
  return (activities ?? []).some((activity) => activity.browser === true);
}

/**
 * `GET /api/v1/browser/frame` for a picture `width` pixels wide (240–1920). With `after` (the `seq` of the picture
 * already shown) the Mac answers as soon as the page changes, or with the same picture after about 8 s.
 */
export function browserFramePath(width: number, after?: number): string {
  const clamped = Math.min(1920, Math.max(240, Math.round(width)));
  return `/api/v1/browser/frame?width=${clamped}${after ? `&after=${after}` : ""}`;
}

/** When to ask for the next picture: right away when the Mac waits for changes (it sends `seq`), else poll. */
export function nextFrameDelay(seq: number | undefined, pollMs: number): number {
  return Number.isInteger(seq) ? 0 : pollMs;
}
