import { describe, expect, it } from "vitest";
import { safeFileName, sniffAttachmentType } from "./fileSignature";

const bytes = (...values: number[]) => new Uint8Array([...values, 0, 0, 0, 0, 0, 0, 0, 0]);

describe("sniffAttachmentType", () => {
  it("recognises PDF, JPEG, PNG and WebP by content", () => {
    expect(sniffAttachmentType(bytes(0x25, 0x50, 0x44, 0x46, 0x2d))).toBe("application/pdf");
    expect(sniffAttachmentType(bytes(0xff, 0xd8, 0xff, 0xe0))).toBe("image/jpeg");
    expect(sniffAttachmentType(bytes(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a))).toBe(
      "image/png",
    );
    expect(
      sniffAttachmentType(
        new Uint8Array([0x52, 0x49, 0x46, 0x46, 1, 2, 3, 4, 0x57, 0x45, 0x42, 0x50]),
      ),
    ).toBe("image/webp");
  });

  it("refuses anything else, whatever it is called", () => {
    expect(sniffAttachmentType(bytes(0x4d, 0x5a))).toBeNull();
    expect(sniffAttachmentType(new Uint8Array())).toBeNull();
  });
});

describe("safeFileName", () => {
  it("removes path separators and control characters", () => {
    expect(safeFileName("a/b\\c\u0000.pdf")).toBe("a-b-c.pdf");
    expect(safeFileName("   ")).toBe("lampiran");
  });
});
