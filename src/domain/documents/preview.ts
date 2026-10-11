/**
 * What the attachment popup can show (decision 408): images and PDFs are shown inside the popup and can be
 * printed or saved as PDF from it; any other type (a spreadsheet, a Word file) only offers the download.
 */
export type PreviewKind = "image" | "pdf" | "none";

export function previewKind(mimeType: string): PreviewKind {
  const type = mimeType.toLowerCase().split(";")[0].trim();
  if (type === "application/pdf") return "pdf";
  if (
    type === "image/png" ||
    type === "image/jpeg" ||
    type === "image/webp" ||
    type === "image/gif"
  )
    return "image";
  return "none";
}
