import { describe, expect, it } from "vitest";
import {
  BLOCK_INFO,
  DEFAULT_INVOICE_LAYOUT,
  GRID_COLUMNS,
  type InvoiceBlockId,
  type InvoiceLayout,
  centerBlock,
  dropBlock,
  isDefaultLayout,
  laneRoom,
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

/** Rows of lanes of block keys: `[[["logo"], ["issuer"], ["title"]], ...]`. */
function rowsOf(layout: InvoiceLayout): string[][][] {
  return layoutRows(layout).map((row) =>
    row.lanes.map((lane) => lane.blocks.map((block) => block.key)),
  );
}

/** Flat keys of a row, left to right and top to bottom. */
function keysOf(layout: InvoiceLayout): string[][] {
  return rowsOf(layout).map((row) => row.flat());
}

/** Lanes of a row never overlap, every lane stays inside the grid and the stack numbers run 1, 2, 3... */
function expectTidy(layout: InvoiceLayout) {
  for (const row of layoutRows(layout)) {
    let end = 0;
    for (const lane of row.lanes) {
      expect(lane.col).toBeGreaterThan(end);
      expect(lane.span).toBeGreaterThanOrEqual(1);
      expect(lane.col + lane.span - 1).toBeLessThanOrEqual(GRID_COLUMNS);
      end = lane.col + lane.span - 1;
      lane.blocks.forEach((block, index) => {
        expect(block.stack).toBe(index + 1);
        expect(block.col).toBe(lane.col);
        expect(block.span).toBe(lane.span);
      });
    }
  }
}

describe("invoice layout on the twenty-four column grid (decisions 310, 318, 319)", () => {
  it("falls back to the standard arrangement for anything unusable", () => {
    for (const value of [null, undefined, "x", 5, [], {}, { blocks: "no" }]) {
      expect(parseInvoiceLayout(value)).toEqual(DEFAULT_INVOICE_LAYOUT);
    }
    expect(isDefaultLayout(parseInvoiceLayout(null))).toBe(true);
  });

  it("the standard arrangement: header on one row, two columns at the bottom", () => {
    expect(rowsOf(DEFAULT_INVOICE_LAYOUT)).toEqual([
      [["logo"], ["issuer"], ["title"]],
      [["customer"], ["dates"]],
      [["lines"]],
      [
        ["payments", "notes", "terms"],
        ["totals", "instructions"],
      ],
    ]);
    expect(at(DEFAULT_INVOICE_LAYOUT, "logo")).toMatchObject({ col: 1, span: 4 });
    expect(at(DEFAULT_INVOICE_LAYOUT, "issuer")).toMatchObject({ col: 5, span: 12 });
    expect(at(DEFAULT_INVOICE_LAYOUT, "title")).toMatchObject({ col: 17, span: 8, align: "right" });
    expect(at(DEFAULT_INVOICE_LAYOUT, "totals")).toMatchObject({ col: 13, span: 12 });
    expectTidy(DEFAULT_INVOICE_LAYOUT);
  });

  it("drops unknown and repeated blocks, restores missing ones and keeps required blocks visible", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      grid: 24,
      blocks: [
        { key: "customer", show: false, align: "center", row: 1, col: 1, span: 24 },
        { key: "script", show: true, align: "left", row: 2, col: 1, span: 24 },
        { key: "customer", show: true, align: "left", row: 3, col: 1, span: 24 },
        { key: "notes", show: false, align: "bogus", row: 4, col: 1, span: 24 },
      ],
    });
    expect(parsed.blocks).toHaveLength(DEFAULT_INVOICE_LAYOUT.blocks.length);
    expect(new Set(parsed.blocks.map((block) => block.key)).size).toBe(parsed.blocks.length);
    expect(parsed.blocks[0]).toMatchObject({ key: "customer", show: true, align: "center" });
    expect(at(parsed, "notes")).toMatchObject({ show: false, align: "left" });
    expectTidy(parsed);
  });

  it("converts a layout saved on twelve columns (every column becomes two)", () => {
    const twelve = parseInvoiceLayout({
      v: 1,
      blocks: [
        { key: "logo", show: true, align: "left", row: 1, col: 1, span: 2 },
        { key: "issuer", show: true, align: "left", row: 1, col: 3, span: 6 },
        { key: "title", show: true, align: "right", row: 1, col: 9, span: 4 },
        { key: "customer", show: true, align: "left", row: 2, col: 1, span: 6 },
        { key: "dates", show: true, align: "left", row: 2, col: 7, span: 6 },
        { key: "lines", show: true, align: "left", row: 3, col: 1, span: 12 },
        { key: "totals", show: true, align: "right", row: 4, col: 1, span: 12 },
        { key: "payments", show: true, align: "left", row: 5, col: 1, span: 12 },
        { key: "instructions", show: true, align: "left", row: 6, col: 1, span: 12 },
        { key: "notes", show: true, align: "left", row: 7, col: 1, span: 12 },
        { key: "terms", show: true, align: "left", row: 8, col: 1, span: 12 },
      ],
    });
    expect(at(twelve, "issuer")).toMatchObject({ col: 5, span: 12 });
    expect(at(twelve, "title")).toMatchObject({ col: 17, span: 8 });
    expect(at(twelve, "dates")).toMatchObject({ col: 13, span: 12 });
    // the totals box was flush right: it stays a half page flush right
    expect(at(twelve, "totals")).toMatchObject({ col: 13, span: 12 });
    expect(keysOf(twelve).slice(0, 4)).toEqual([
      ["logo", "issuer", "title"],
      ["customer", "dates"],
      ["lines"],
      ["totals"],
    ]);
    expectTidy(twelve);
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
    expect(keysOf(old).slice(0, 4)).toEqual([
      ["logo"],
      ["issuer", "title"],
      ["customer", "dates"],
      ["lines"],
    ]);
    expect(at(old, "issuer")).toMatchObject({ col: 1, span: 12 });
    expect(at(old, "title")).toMatchObject({ col: 13, span: 12 });
    expect(at(old, "logo")).toMatchObject({ col: 1, span: 24 });

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
    expect(keysOf(withFit)[0]).toEqual(["logo", "issuer", "title"]);
    expect(at(withFit, "logo")).toMatchObject({ col: 1, span: 4 });
    expect(at(withFit, "issuer")).toMatchObject({ col: 5, span: 10 });
    expect(at(withFit, "title")).toMatchObject({ col: 15, span: 10 });
    expectTidy(withFit);
  });

  it("separates lanes stored on top of each other", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      grid: 24,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) =>
        block.key === "notes" ? { ...block, row: 1, col: 3, span: 6 } : block,
      ),
    });
    expectTidy(parsed);
    expect(keysOf(parsed).flat()).toHaveLength(11);
  });

  it("keeps the item table on a row of its own", () => {
    const parsed = parseInvoiceLayout({
      v: 1,
      grid: 24,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) =>
        block.key === "notes" ? { ...block, row: 3, col: 1, span: 6 } : block,
      ),
    });
    expect(keysOf(parsed).find((row) => row.includes("lines"))).toEqual(["lines"]);
    expectTidy(parsed);
  });

  it("ignores a change a block does not allow", () => {
    const hidden = updateBlock(DEFAULT_INVOICE_LAYOUT, "lines", { show: false, align: "right" });
    expect(at(hidden, "lines")).toMatchObject({ show: true, align: "left" });
    const totals = updateBlock(DEFAULT_INVOICE_LAYOUT, "totals", { align: "right" });
    expect(at(totals, "totals").align).toBe("left");
    const notes = updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { show: false, align: "right" });
    expect(at(notes, "notes")).toMatchObject({ show: false, align: "right" });
    // the rest of the lane closes up
    expect(keysOf(notes)[3]).toEqual(["payments", "terms", "totals", "instructions"]);
    expectTidy(notes);
  });

  it("keeps a lane inside the free columns of its row when placing and resizing it", () => {
    expect(placementBounds(DEFAULT_INVOICE_LAYOUT, "issuer")).toEqual({ min: 5, max: 16 });
    const wide = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { span: 20 });
    expect(at(wide, "issuer")).toMatchObject({ col: 5, span: 12 });
    const left = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { col: 1 });
    expect(at(left, "issuer")).toMatchObject({ col: 5, span: 12 });
    const narrow = setPlacement(DEFAULT_INVOICE_LAYOUT, "issuer", { span: 6 });
    expect(at(narrow, "issuer")).toMatchObject({ col: 5, span: 6 });
    // the item table cannot be resized
    expect(setPlacement(DEFAULT_INVOICE_LAYOUT, "lines", { span: 4 })).toEqual(
      DEFAULT_INVOICE_LAYOUT,
    );
  });

  it("resizing one block resizes its whole lane", () => {
    const narrow = setPlacement(DEFAULT_INVOICE_LAYOUT, "notes", { span: 8 });
    for (const key of ["payments", "notes", "terms"] as const) {
      expect(at(narrow, key)).toMatchObject({ col: 1, span: 8 });
    }
    expect(at(narrow, "totals")).toMatchObject({ col: 13, span: 12 });
    expectTidy(narrow);
  });

  it("centres a block and reports the free columns on both sides", () => {
    const narrow = setPlacement(DEFAULT_INVOICE_LAYOUT, "customer", { span: 8 });
    expect(pageMargins(narrow, "customer")).toEqual({ left: 0, right: 16 });
    const centred = centerBlock(narrow, "customer");
    // only the free columns left of the dates are used
    expect(at(centred, "customer")).toMatchObject({ col: 3, span: 8 });
    expect(pageMargins(centred, "customer")).toEqual({ left: 2, right: 14 });
    const alone = setPlacement(DEFAULT_INVOICE_LAYOUT, "lines", { span: 10 });
    expect(alone).toEqual(DEFAULT_INVOICE_LAYOUT);
  });

  it("drops a block above or below a row, as a row of its own", () => {
    const small = setPlacement(DEFAULT_INVOICE_LAYOUT, "customer", { span: 8 });
    const above = dropBlock(small, "customer", { mode: "row", at: "before", row: 3, col: 5 });
    expect(keysOf(above).slice(0, 4)).toEqual([
      ["logo", "issuer", "title"],
      ["dates"],
      ["customer"],
      ["lines"],
    ]);
    expect(at(above, "customer")).toMatchObject({ col: 5, span: 8 });
    expectTidy(above);

    const below = dropBlock(DEFAULT_INVOICE_LAYOUT, "dates", { mode: "row", at: "after", row: 3 });
    expect(keysOf(below).slice(2, 4)).toEqual([["lines"], ["dates"]]);
  });

  it("stacks a block under another in the same lane, so the space under a short block is usable", () => {
    // the customer goes right under the company name, beside the logo
    const stacked = dropBlock(DEFAULT_INVOICE_LAYOUT, "customer", {
      mode: "stack",
      at: "after",
      target: "issuer",
    });
    expect(rowsOf(stacked)[0]).toEqual([["logo"], ["issuer", "customer"], ["title"]]);
    expect(at(stacked, "customer")).toMatchObject({ col: 5, span: 12, row: 1, stack: 2 });
    expect(keysOf(stacked)[1]).toEqual(["dates"]);
    expectTidy(stacked);

    // above the first block of a lane
    const first = dropBlock(DEFAULT_INVOICE_LAYOUT, "dates", {
      mode: "stack",
      at: "before",
      target: "issuer",
    });
    expect(rowsOf(first)[0]![1]).toEqual(["dates", "issuer"]);

    // reordering inside a lane
    const reordered = dropBlock(DEFAULT_INVOICE_LAYOUT, "terms", {
      mode: "stack",
      at: "before",
      target: "payments",
    });
    expect(rowsOf(reordered)[3]![0]).toEqual(["terms", "payments", "notes"]);
    expectTidy(reordered);

    // the item table never joins a lane, and nothing joins the item table's lane
    const table = dropBlock(DEFAULT_INVOICE_LAYOUT, "lines", {
      mode: "stack",
      at: "after",
      target: "customer",
    });
    expect(keysOf(table)[2]).toEqual(["lines"]);
    const underTable = dropBlock(DEFAULT_INVOICE_LAYOUT, "notes", {
      mode: "stack",
      at: "before",
      target: "lines",
    });
    expect(keysOf(underTable).find((row) => row.includes("lines"))).toEqual(["lines"]);
    expectTidy(table);
    expectTidy(underTable);
  });

  it("drops a block into a row as a lane of its own, or onto a row below when the columns are taken", () => {
    const room = setPlacement(DEFAULT_INVOICE_LAYOUT, "customer", { span: 8 });
    expect(laneRoom(room, "notes", 2, 10)).toEqual({ col: 9, span: 4 });
    const into = dropBlock(room, "notes", { mode: "lane", row: 2, col: 10 });
    expect(rowsOf(into)[1]).toEqual([["customer"], ["notes"], ["dates"]]);
    expect(at(into, "notes")).toMatchObject({ col: 9, span: 4 });
    expectTidy(into);

    const taken = dropBlock(DEFAULT_INVOICE_LAYOUT, "notes", { mode: "lane", row: 2, col: 3 });
    expect(laneRoom(DEFAULT_INVOICE_LAYOUT, "notes", 2, 3)).toBeNull();
    expect(keysOf(taken)[1]).toEqual(["customer", "dates"]);
    expect(keysOf(taken)[2]).toEqual(["notes"]);

    // the item table and its row never take a lane
    const table = dropBlock(DEFAULT_INVOICE_LAYOUT, "lines", { mode: "lane", row: 2, col: 3 });
    expect(keysOf(table)[1]).toEqual(["customer", "dates"]);
    expect(at(table, "lines")).toMatchObject({ col: 1, span: 24 });
    const beside = dropBlock(DEFAULT_INVOICE_LAYOUT, "notes", { mode: "lane", row: 3, col: 3 });
    expect(keysOf(beside).find((row) => row.includes("lines"))).toEqual(["lines"]);
    expectTidy(table);
    expectTidy(beside);
  });

  it("slides a block sideways inside its own row", () => {
    const small = setPlacement(DEFAULT_INVOICE_LAYOUT, "logo", { span: 2 });
    const slid = dropBlock(small, "logo", { mode: "lane", row: 1, col: 3 });
    expect(at(slid, "logo")).toMatchObject({ col: 3, span: 2, row: 1 });
    // wanting more columns than the gap holds makes the block narrower
    const tight = dropBlock(DEFAULT_INVOICE_LAYOUT, "title", { mode: "lane", row: 1, col: 20 });
    expect(at(tight, "title")).toMatchObject({ col: 17, span: 8 });
    expectTidy(slid);
    expectTidy(tight);
  });

  it("moving the logo out of its lane leaves the company and the title in place", () => {
    const moved = dropBlock(DEFAULT_INVOICE_LAYOUT, "logo", { mode: "row", at: "before", row: 1 });
    expect(rowsOf(moved).slice(0, 2)).toEqual([[["logo"]], [["issuer"], ["title"]]]);
    expectTidy(moved);
  });

  it("moves a block up or down for touch screens", () => {
    // inside a lane: past the neighbour
    const down = shiftRow(DEFAULT_INVOICE_LAYOUT, "payments", "down");
    expect(rowsOf(down)[3]![0]).toEqual(["notes", "payments", "terms"]);
    // the first block of a lane: out into a row of its own
    const out = shiftRow(DEFAULT_INVOICE_LAYOUT, "payments", "up");
    expect(keysOf(out)[3]).toEqual(["payments"]);
    // a block that is alone in its row: past the neighbouring row
    const alone = shiftRow(DEFAULT_INVOICE_LAYOUT, "lines", "up");
    expect(keysOf(alone).slice(1, 3)).toEqual([["lines"], ["customer", "dates"]]);
    // the top of the page cannot go further for a block alone in its row
    const top = shiftRow(shiftRow(alone, "lines", "up"), "lines", "up");
    expect(keysOf(top)[0]).toEqual(["lines"]);
    expect(shiftRow(top, "lines", "up")).toEqual(top);
    expectTidy(down);
    expectTidy(out);
    expectTidy(alone);
  });

  it("showing a hidden block again never overlaps what took its place", () => {
    const hidden = updateBlock(DEFAULT_INVOICE_LAYOUT, "logo", { show: false });
    const grown = setPlacement(hidden, "issuer", { col: 1, span: 12 });
    expect(at(grown, "issuer")).toMatchObject({ col: 1, span: 12 });
    const back = updateBlock(grown, "logo", { show: true });
    expect(at(back, "logo").show).toBe(true);
    expectTidy(back);
    // a block hidden from the middle of a lane returns to the end of it
    const noNotes = updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { show: false });
    const again = updateBlock(noNotes, "notes", { show: true });
    expect(rowsOf(again)[3]![0]).toEqual(["payments", "terms", "notes"]);
    expectTidy(again);
  });

  it("marks exactly the six blocks that carry numbers, parties, dates and amounts as required", () => {
    const required = Object.entries(BLOCK_INFO)
      .filter(([, info]) => info.required)
      .map(([key]) => key)
      .sort();
    expect(required).toEqual(["customer", "dates", "issuer", "lines", "title", "totals"]);
  });
});
