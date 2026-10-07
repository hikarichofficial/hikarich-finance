import { describe, expect, it } from "vitest";
import { alignmentGuides } from "./invoiceGuides";
import { DEFAULT_INVOICE_LAYOUT, dropBlock, setPlacement } from "./invoiceLayout";

describe("alignment guides (decision 319)", () => {
  it("says when a block is exactly in the middle of the page", () => {
    const centred = setPlacement(
      dropBlock(DEFAULT_INVOICE_LAYOUT, "notes", { mode: "row", at: "after", row: 4, col: 7 }),
      "notes",
      { col: 7, span: 12 },
    );
    expect(alignmentGuides(centred, "notes")).toContainEqual({
      edge: "center",
      at: 12,
      label: "Tepat di tengah halaman",
    });
  });

  it("says when a block touches the page edges", () => {
    const guides = alignmentGuides(DEFAULT_INVOICE_LAYOUT, "customer");
    expect(guides).toContainEqual({ edge: "left", at: 0, label: "Tepi kiri halaman" });
    expect(alignmentGuides(DEFAULT_INVOICE_LAYOUT, "title")).toContainEqual({
      edge: "right",
      at: 24,
      label: "Tepi kanan halaman",
    });
  });

  it("lines a block up with other blocks, but not with the blocks of its own lane", () => {
    // the dates start where the totals start (column 13): lined up on the left
    const guides = alignmentGuides(DEFAULT_INVOICE_LAYOUT, "dates");
    expect(guides.some((guide) => guide.edge === "left" && guide.label.includes("Total"))).toBe(
      true,
    );
    // the notes share a lane with the payments: that is not reported
    const notes = alignmentGuides(DEFAULT_INVOICE_LAYOUT, "notes");
    expect(notes.some((guide) => guide.label.includes("Pembayaran diterima"))).toBe(false);
  });

  it("reports nothing for a hidden or unknown block", () => {
    expect(alignmentGuides({ ...DEFAULT_INVOICE_LAYOUT, blocks: [] }, "logo")).toEqual([]);
  });
});
