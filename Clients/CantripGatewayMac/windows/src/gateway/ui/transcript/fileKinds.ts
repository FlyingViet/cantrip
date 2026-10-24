// What kind of attachment a file is, kept free of browser-only imports so tests can load it.

export function isImageFile(file: File): boolean {
  return /^image\/(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(file.type) || /\.(png|jpe?g|gif|webp|bmp|heic|heif|avif)$/i.test(file.name);
}

export function isVideoFile(file: File): boolean {
  return /\.(mov|mp4)$/i.test(file.name) || file.type === "video/mp4" || file.type === "video/quicktime";
}

/** What a paste into the message box attaches: copied files of any kind, and a copied image such
 * as a screenshot. Text wins when the clipboard has only images besides it (Excel, Word and web
 * pages put a picture of the copied text there too), like Cantrip on the Mac. */
export function pastedFiles(data: Pick<DataTransfer, "files" | "types" | "getData"> | null): File[] {
  const files = Array.from(data?.files ?? []);
  if (!files.length) return [];
  const hasText = data!.types.includes("text/plain") && data!.getData("text/plain").trim() !== "";
  return hasText && files.every(isImageFile) ? [] : files;
}
