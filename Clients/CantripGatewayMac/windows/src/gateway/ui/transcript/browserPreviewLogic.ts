// Pure helpers for BrowserPreview.tsx (no window bridge), so tests can import them.

/** True when any tool call in the reply came from the Mac's browser MCP server (`activity.browser`). */
export function usesBrowser(activities: { browser?: boolean }[] | undefined): boolean {
  return (activities ?? []).some((activity) => activity.browser === true);
}
