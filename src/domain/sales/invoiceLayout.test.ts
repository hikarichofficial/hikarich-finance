import { describe, expect, it } from "vitest";
import {
  BLOCK_INFO,
  DEFAULT_INVOICE_LAYOUT,
  isDefaultLayout,
  layoutRows,
  moveBlock,
  parseInvoiceLayout,
  updateBlock,
} from "./invoiceLayout";

describe("invoice layout (decision 310)", () => {
  it("falls back to the standard arrangement for anything unusable", () => {
    for (const value of [null, undefined, "x", 5, [], {}, { blocks: "no" }]) {
      expect(parseInvoiceLayout(value)).toEqual(DEFAULT_INVOICE_LAYOUT);
    }
    expect(isDefaultLayout(parseInvoiceLayout(null))).toBe(true);
  });

  it("drops unknown and repeated blocks, restores missing ones and keeps required blocks visible", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      blocks: [
        { key: "totals", show: false, align: "center", width: "half" },
        { key: "script", show: true, align: "left", width: "full" },
        { key: "totals", show: true, align: "left", width: "full" },
        { key: "notes", show: false, align: "bogus", width: "bogus" },
      ],
    });
    expect(parsed.blocks).toHaveLength(DEFAULT_INVOICE_LAYOUT.blocks.length);
    expect(new Set(parsed.blocks.map((block) => block.key)).size).toBe(parsed.blocks.length);
    expect(parsed.blocks[0]).toMatchObject({
      key: "totals",
      show: true,
      align: "center",
      width: "full",
    });
    expect(parsed.blocks.find((block) => block.key === "notes")).toMatchObject({
      show: false,
      align: "left",
      width: "full",
    });
  });

  it("moves a block and ignores a change the block does not allow", () => {
    const moved = moveBlock(DEFAULT_INVOICE_LAYOUT, "title", 0);
    expect(moved.blocks[0]!.key).toBe("title");
    expect(moved.blocks).toHaveLength(DEFAULT_INVOICE_LAYOUT.blocks.length);

    const hidden = updateBlock(DEFAULT_INVOICE_LAYOUT, "lines", {
      show: false,
      width: "half",
      align: "right",
    });
    expect(hidden.blocks.find((block) => block.key === "lines")).toMatchObject({
      show: true,
      width: "full",
      align: "left",
    });
    const notes = updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { show: false, align: "right" });
    expect(notes.blocks.find((block) => block.key === "notes")).toMatchObject({
      show: false,
      align: "right",
    });
  });

  it("puts the logo, the company and the title in one row, then two neighbouring half-width blocks", () => {
    const rows = layoutRows(DEFAULT_INVOICE_LAYOUT);
    expect(rows[0]!.map((block) => block.key)).toEqual(["logo", "issuer", "title"]);
    expect(rows[1]!.map((block) => block.key)).toEqual(["customer", "dates"]);
    expect(rows.flat()).toHaveLength(DEFAULT_INVOICE_LAYOUT.blocks.length);
  });

  it("a lone half-width block gets a row of its own and hidden blocks take no place", () => {
    const layout = updateBlock(
      updateBlock(DEFAULT_INVOICE_LAYOUT, "title", { show: true }),
      "logo",
      { show: false },
    );
    expect(
      layoutRows(layout)
        .flat()
        .some((block) => block.key === "logo"),
    ).toBe(false);
    const single = updateBlock(DEFAULT_INVOICE_LAYOUT, "dates", { width: "full" });
    expect(
      layoutRows(single).find((row) => row.some((block) => block.key === "customer")),
    ).toHaveLength(1);
  });

  it("a full-width logo keeps its own row, and a fit block never joins a row that already holds two halves", () => {
    const stacked = updateBlock(DEFAULT_INVOICE_LAYOUT, "logo", { width: "full" });
    expect(layoutRows(stacked)[0]!.map((block) => block.key)).toEqual(["logo"]);
    expect(layoutRows(stacked)[1]!.map((block) => block.key)).toEqual(["issuer", "title"]);
    const moved = moveBlock(DEFAULT_INVOICE_LAYOUT, "logo", 2);
    expect(layoutRows(moved)[0]!.map((block) => block.key)).toEqual(["issuer", "title"]);
    // the logo then sits with the next row of halves, never inside a row that is already full
    expect(layoutRows(moved)[1]!.map((block) => block.key)).toEqual(["logo", "customer", "dates"]);
  });

  it("accepts the fit width from storage", () => {
    const layout = parseInvoiceLayout({
      v: 1,
      blocks: [{ key: "logo", show: true, align: "left", width: "fit" }],
    });
    expect(layout.blocks.find((block) => block.key === "logo")!.width).toBe("fit");
  });

  it("marks exactly the six blocks that carry numbers, parties, dates and amounts as required", () => {
    const required = Object.entries(BLOCK_INFO)
      .filter(([, info]) => info.required)
      .map(([key]) => key)
      .sort();
    expect(required).toEqual(["customer", "dates", "issuer", "lines", "title", "totals"]);
  });
});
