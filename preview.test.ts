import { describe, expect, it } from "vitest";
import { previewKind } from "./preview";

describe("previewKind", () => {
  it("shows images and PDFs, nothing else", () => {
    expect(previewKind("application/pdf")).toBe("pdf");
    expect(previewKind("image/png")).toBe("image");
    expect(previewKind("IMAGE/JPEG; charset=binary")).toBe("image");
    expect(previewKind("text/csv")).toBe("none");
    expect(
      previewKind("application/vnd.openxmlformats-officedocument.wordprocessingml.document"),
    ).toBe("none");
  });
});
