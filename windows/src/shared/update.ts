export function sanitizeUpdateError(error: unknown): string {
  const raw = error instanceof Error ? error.message : String(error);
  if (/\b404\b/.test(raw)) {
    return "the GitHub release feed has not been published yet.";
  }
  const firstLine = raw.split(/\r?\n/, 1)[0].trim();
  return (firstLine || "unknown updater error").slice(0, 180);
}
