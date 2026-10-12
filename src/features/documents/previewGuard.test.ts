import { readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";
import { describe, expect, it } from "vitest";

/**
 * One preview for every attachment (decision 411): a screen that shows an attached file does it through
 * `AttachmentPreviewLink`, never with its own link to the download or view route. A second way of opening a
 * file would mean some attachments open differently from the rest, so any screen that builds such a link
 * itself fails here.
 */
function sourceFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return sourceFiles(path);
    return /\.(ts|tsx)$/.test(name) && !/\.test\./.test(name) ? [path] : [];
  });
}

describe("attachment preview", () => {
  it("is the only place that links to the document view and download routes", () => {
    const offenders = sourceFiles("src")
      .filter((file) => !file.startsWith(join("src", "app", "(app)", "documents")))
      .filter((file) => !file.endsWith("AttachmentPreviewLink.tsx"))
      .filter((file) => /documents\/(view|download)\//.test(readFileSync(file, "utf8")));
    expect(offenders).toEqual([]);
  });
});
