import { describe, expect, it } from "vitest";
import {
  BLOCK_INFO,
  DEFAULT_INVOICE_LAYOUT,
  type InvoiceBlockId,
  type InvoiceLayout,
  centerBlock,
  dropBlock,
  isDefaultLayout,
  layoutRows,
  pageMargins,
  parseInvoiceLayout,
  placementBounds,
  setPlacement,
  shiftRow,
  updateBlock,
} from "./invoiceLayout";

function at(layout: InvoiceLayout, key: InvoiceBlockId) {
  return layout.blocks.find((block) => block.key === key)!;
}

function rowsOf(layout: InvoiceLayout): string[][] {
  return layoutRows(layout).map((row) => row.map((block) => block.key));
}

/** Two blocks never share a column on a row, and every block stays inside the twelve columns. */
function expectTidy(layout: InvoiceLayout) {
  for (const row of layoutRows(layout)) {
    let end = 0;
    for (const block of row) {
      expect(block.col).toBeGreaterThan(end);
      expect(block.span).toBeGreaterThanOrEqual(1);
      expect(block.col + block.span - 1).toBeLessThanOrEqual(12);
      end = block.col + block.span - 1;
    }
  }
}

describe("invoice layout on the twelve-column grid (decisions 310, 318)", () => {
  it("falls back to the standard arrangement for anything unusable", () => {
    for (const value of [null, undefined, "x", 5, [], {}, { blocks: "no" }]) {
      expect(parseInvoiceLayout(value)).toEqual(DEFAULT_INVOICE_LAYOUT);
    }
    expect(isDefaultLayout(parseInvoiceLayout(null))).toBe(true);
  });

  it("the standard arrangement puts the logo, the company and the title in one row", () => {
    expect(rowsOf(DEFAULT_INVOICE_LAYOUT).slice(0, 3)).toEqual([
      ["logo", "issuer", "title"],
      ["customer", "dates"],
      ["lines"],
    ]);
    expect(at(DEFAULT_INVOICE_LAYOUT, "logo")).toMatchObject({ col: 1, span: 2 });
    expect(at(DEFAULT_INVOICE_LAYOUT, "issuer")).toMatchObject({ col: 3, span: 6 });
    expect(at(DEFAULT_INVOICE_LAYOUT, "title")).toMatchObject({ col: 9, span: 4, align: "right" });
    expectTidy(DEFAULT_INVOICE_LAYOUT);
  });

  it("drops unknown and repeated blocks, restores missing ones and keeps required blocks visible", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      blocks: [
        { key: "totals", show: false, align: "center", row: 1, col: 1, span: 12 },
        { key: "script", show: true, align: "left", row: 2, col: 1, span: 12 },
        { key: "totals", show: true, align: "left", row: 3, col: 1, span: 12 },
        { key: "notes", show: false, align: "bogus", row: 4, col: 1, span: 12 },
      ],
    });
    expect(parsed.blocks).toHaveLength(DEFAULT_INVOICE_LAYOUT.blocks.length);
    expect(new Set(parsed.blocks.map((block) => block.key)).size).toBe(parsed.blocks.length);
    expect(parsed.blocks[0]).toMatchObject({ key: "totals", show: true, align: "center" });
    expect(at(parsed, "notes")).toMatchObject({ show: false, align: "left" });
    expectTidy(parsed);
  });

  it("converts a layout saved before the grid (half, full and fit widths)", () => {
    const old = parseInvoiceLayout({
      v: 1,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) => ({
        key: block.key,
        show: true,
        align: block.key === "title" || block.key === "totals" ? "right" : "left",
        width: ["issuer", "title", "customer", "dates"].includes(block.key) ? "half" : "full",
      })),
    });
    expect(rowsOf(old).slice(0, 4)).toEqual([
      ["logo"],
      ["issuer", "title"],
      ["customer", "dates"],
      ["lines"],
    ]);
    expect(at(old, "issuer")).toMatchObject({ col: 1, span: 6 });
    expect(at(old, "title")).toMatchObject({ col: 7, span: 6 });
    expect(at(old, "logo")).toMatchObject({ col: 1, span: 12 });

    const withFit = parseInvoiceLayout({
      v: 1,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) => ({
        key: block.key,
        show: true,
        align: "left",
        width:
          block.key === "logo" ? "fit" : ["issuer", "title"].includes(block.key) ? "half" : "full",
      })),
    });
    expect(rowsOf(withFit)[0]).toEqual(["logo", "issuer", "title"]);
    expect(at(withFit, "logo")).toMatchObject({ col: 1, span: 2 });
    expect(at(withFit, "issuer")).toMatchObject({ col: 3, span: 5 });
    expect(at(withFit, "title")).toMatchObject({ col: 8, span: 5 });
    expectTidy(withFit);
  });

  it("separates blocks stored on top of each other", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) =>
        block.key === "notes" ? { ...block, row: 1, col: 1, span: 12 } : block,
      ),
    });
    expectTidy(parsed);
    expect(rowsOf(parsed).flat()).toHaveLength(11);
  });

  it("ignores a change a block does not allow", () => {
    const hidden = updateBlock(DEFAULT_INVOICE_LAYOUT, "lines", { show: false, align: "right" });
    expect(at(hidden, "lines")).toMatchObject({ show: true, align: "left" });
    const notes = updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { show: false, align: "right" });
    expect(at(notes, "notes")).toMatchObject({ show: false, align: "right" });
  });

  it("keeps a block inside the free columns of its row when placing and resizing it", () => {
    expect(placementBounds(DEFAULT_INVOICE_LAYOUT, "issuer")).toEqual({ min: 3, max: 8 });
    const wide = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { span: 10 });
    expect(at(wide, "issuer")).toMatchObject({ col: 3, span: 6 });
    const left = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { col: 1 });
    expect(at(left, "issuer")).toMatchObject({ col: 3, span: 6 });
    const narrow = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { span: 3 });
    expect(at(narrow, "issuer")).toMatchObject({ col: 3, span: 3 });
    // the item table and the totals box cannot be resized
    expect(setPlacement(DEFAULT_INVOICE_LAYOUT, "lines", { span: 4 })).toEqual(
      DEFAULT_INVOICE_LAYOUT,
    );
  });

  it("centres a block and reports the free columns on both sides", () => {
    const narrow = setPlacement(DEFAULT_INVOICE_LAYOUT, "notes", { span: 6 });
    expect(pageMargins(narrow, "notes")).toEqual({ left: 0, right: 6 });
    const centred = centerBlock(narrow, "notes");
    expect(at(centred, "notes")).toMatchObject({ col: 4, span: 6 });
    expect(pageMargins(centred, "notes")).toEqual({ left: 3, right: 3 });
  });

  it("drops a block above or below a row, into a row, or onto a taken column", () => {
    // above the item table: a row of its own, at the column it was dropped
    const small = setPlacement(DEFAULT_INVOICE_LAYOUT, "terms", { span: 6 });
    const above = dropBlock(small, "terms", { mode: "before", target: "lines", col: 4 });
    expect(rowsOf(above)[2]).toEqual(["terms"]);
    expect(at(above, "terms")).toMatchObject({ col: 4, span: 6 });
    expect(rowsOf(above)[3]).toEqual(["lines"]);
    expectTidy(above);

    // into the customer row where two columns are free
    const room = setPlacement(DEFAULT_INVOICE_LAYOUT, "customer", { span: 4 });
    const into = dropBlock(room, "notes", { mode: "into", target: "customer", col: 5 });
    expect(rowsOf(into)[1]).toEqual(["customer", "notes", "dates"]);
    expect(at(into, "notes")).toMatchObject({ col: 5, span: 2 });
    expectTidy(into);

    // a taken column puts the block on a row of its own below
    const taken = dropBlock(DEFAULT_INVOICE_LAYOUT, "notes", {
      mode: "into",
      target: "customer",
      col: 3,
    });
    expect(rowsOf(taken)[1]).toEqual(["customer", "dates"]);
    expect(rowsOf(taken)[2]).toEqual(["notes"]);

    // the item table and the totals box never share a row
    const table = dropBlock(DEFAULT_INVOICE_LAYOUT, "lines", {
      mode: "into",
      target: "customer",
      col: 3,
    });
    expect(rowsOf(table)[1]).toEqual(["customer", "dates"]);
    expect(at(table, "lines")).toMatchObject({ col: 1, span: 12 });
    expectTidy(table);
  });

  it("moving the logo out of its row leaves the company and the title in place", () => {
    const moved = dropBlock(DEFAULT_INVOICE_LAYOUT, "logo", { mode: "before", target: "issuer" });
    expect(rowsOf(moved).slice(0, 2)).toEqual([["logo"], ["issuer", "title"]]);
    expectTidy(moved);
  });

  it("moves a block up or down for touch screens", () => {
    const up = shiftRow(DEFAULT_INVOICE_LAYOUT, "issuer", "up");
    expect(rowsOf(up).slice(0, 2)).toEqual([["issuer"], ["logo", "title"]]);
    const down = shiftRow(DEFAULT_INVOICE_LAYOUT, "customer", "down");
    expect(rowsOf(down).slice(1, 3)).toEqual([["dates"], ["customer"]]);
    // the first row cannot go further up
    expect(rowsOf(shiftRow(DEFAULT_INVOICE_LAYOUT, "issuer", "up")).length).toBe(
      rowsOf(DEFAULT_INVOICE_LAYOUT).length + 1,
    );
    const alone = shiftRow(DEFAULT_INVOICE_LAYOUT, "lines", "up");
    expect(rowsOf(alone).slice(1, 3)).toEqual([["lines"], ["customer", "dates"]]);
    expectTidy(up);
    expectTidy(down);
    expectTidy(alone);
  });

  it("showing a hidden block again never overlaps what took its place", () => {
    const hidden = updateBlock(DEFAULT_INVOICE_LAYOUT, "logo", { show: false });
    const grown = setPlacement(hidden, "issuer", { col: 1, span: 8 });
    expect(at(grown, "issuer")).toMatchObject({ col: 1, span: 8 });
    const back = updateBlock(grown, "logo", { show: true });
    expect(at(back, "logo").show).toBe(true);
    expectTidy(back);
  });

  it("marks exactly the six blocks that carry numbers, parties, dates and amounts as required", () => {
    const required = Object.entries(BLOCK_INFO)
      .filter(([, info]) => info.required)
      .map(([key]) => key)
      .sort();
    expect(required).toEqual(["customer", "dates", "issuer", "lines", "title", "totals"]);
  });
});
