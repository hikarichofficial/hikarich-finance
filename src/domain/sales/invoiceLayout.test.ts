import { describe, expect, it } from "vitest";
import {
  BLOCK_INFO,
  DEFAULT_INVOICE_LAYOUT,
  alignToPage,
  canFollow,
  descendants,
  isDefaultLayout,
  parseInvoiceLayout,
  resolveTree,
  updateBlock,
  type InvoiceBlockId,
} from "./invoiceLayout";

const find = (layout: ReturnType<typeof parseInvoiceLayout>, key: InvoiceBlockId) =>
  layout.blocks.find((entry) => entry.key === key)!;

describe("the standard invoice arrangement (decision 321)", () => {
  it("is the original look: logo, company name and title on top, items, totals and closing blocks below", () => {
    const layout = DEFAULT_INVOICE_LAYOUT;
    expect(layout.v).toBe(2);
    expect(find(layout, "issuer").after).toBe("logo");
    expect(find(layout, "title")).toMatchObject({ x: 60, w: 40, align: "right", after: "logo" });
    expect(find(layout, "customer").after).toBe("issuer");
    expect(find(layout, "lines")).toMatchObject({ zone: "table", x: 0, w: 100 });
    expect(find(layout, "payments")).toMatchObject({ zone: "foot", x: 0, w: 100, after: "totals" });
    expect(find(layout, "terms").after).toBe("notes");
  });

  it("is its own parse result and is recognised as the standard", () => {
    expect(parseInvoiceLayout(DEFAULT_INVOICE_LAYOUT)).toEqual(DEFAULT_INVOICE_LAYOUT);
    expect(isDefaultLayout(DEFAULT_INVOICE_LAYOUT)).toBe(true);
    expect(isDefaultLayout(updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { size: "lg" }))).toBe(
      false,
    );
  });
});

describe("parseInvoiceLayout", () => {
  it("turns nothing, rubbish and layouts of the old grid (version 1) into the standard", () => {
    for (const value of [
      null,
      undefined,
      "x",
      3,
      [],
      {},
      { v: 1, blocks: [] },
      { v: 1, grid: 24 },
    ]) {
      expect(parseInvoiceLayout(value)).toEqual(DEFAULT_INVOICE_LAYOUT);
    }
  });

  it("drops unknown and repeated blocks and adds missing ones back at their standard place", () => {
    const layout = parseInvoiceLayout({
      v: 2,
      blocks: [
        { ...find(DEFAULT_INVOICE_LAYOUT, "notes"), x: 10, w: 50 },
        { key: "script", show: true },
        { ...find(DEFAULT_INVOICE_LAYOUT, "notes"), x: 40, w: 50 },
      ],
    });
    expect(layout.blocks).toHaveLength(11);
    expect(find(layout, "notes").x).toBe(10);
    expect(layout.blocks[0]!.key).toBe("notes");
    expect(find(layout, "logo")).toEqual(find(DEFAULT_INVOICE_LAYOUT, "logo"));
  });

  it("puts values out of range back into range and never throws", () => {
    const layout = parseInvoiceLayout({
      v: 2,
      blocks: [
        {
          ...find(DEFAULT_INVOICE_LAYOUT, "notes"),
          x: 90,
          w: 40,
          y: -5,
          h: 99999,
          align: "diagonal",
        },
        { ...find(DEFAULT_INVOICE_LAYOUT, "terms"), w: 1, x: "left", size: "huge" },
      ],
    });
    expect(find(layout, "notes")).toMatchObject({ w: 40, x: 60, y: 0, h: 600, align: "left" });
    expect(find(layout, "terms")).toMatchObject({ w: 8, size: "md" });
  });

  it("never hides the blocks that carry the numbers and keeps the item table full width", () => {
    const layout = parseInvoiceLayout({
      v: 2,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => ({
        ...entry,
        show: false,
        ...(entry.key === "lines" ? { x: 20, w: 30, zone: "head", after: "logo" } : {}),
      })),
    });
    for (const [key, info] of Object.entries(BLOCK_INFO)) {
      expect(find(layout, key as InvoiceBlockId).show).toBe(!info.required ? false : true);
    }
    expect(find(layout, "lines")).toMatchObject({ x: 0, w: 100, zone: "table", after: null });
  });

  it("keeps every stored number whole and in range, also on the item table", () => {
    const layout = parseInvoiceLayout({
      v: 2,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => ({ ...entry, y: 3.7, h: 261.96 })),
    });
    for (const entry of layout.blocks) {
      expect(Number.isInteger(entry.y)).toBe(true);
      expect(Number.isInteger(entry.h)).toBe(true);
    }
    expect(find(layout, "lines")).toMatchObject({ y: 0, h: 0 });
  });

  it("cuts a chain of followers that loops or points at the item table or at nothing", () => {
    const layout = parseInvoiceLayout({
      v: 2,
      blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) =>
        entry.key === "logo"
          ? { ...entry, after: "terms" }
          : entry.key === "totals"
            ? { ...entry, after: "lines" }
            : entry.key === "notes"
              ? { ...entry, after: "notes" }
              : entry,
      ),
    });
    expect(find(layout, "totals").after).toBeNull();
    expect(find(layout, "notes").after).toBeNull();
    // logo -> terms -> notes -> (cut): no loop is left, whichever link was cut.
    const seen = new Set<string>();
    let at: InvoiceBlockId | null = "logo";
    while (at) {
      expect(seen.has(at)).toBe(false);
      seen.add(at);
      at = find(layout, at).after;
    }
  });

  it("gives a follower the zone of the block it follows", () => {
    const layout = updateBlock(DEFAULT_INVOICE_LAYOUT, "totals", { zone: "head" });
    expect(find(layout, "payments").zone).toBe("head");
    expect(find(layout, "terms").zone).toBe("head");
    expect(find(layout, "lines").zone).toBe("table");
  });
});

describe("moving and placing", () => {
  it("keeps a block inside the page", () => {
    const layout = updateBlock(DEFAULT_INVOICE_LAYOUT, "customer", { x: 80, w: 50 });
    expect(find(layout, "customer")).toMatchObject({ w: 50, x: 50 });
    expect(find(updateBlock(layout, "customer", { x: -4 }), "customer").x).toBe(0);
  });

  it("puts a block against the left, the middle or the right edge", () => {
    expect(find(alignToPage(DEFAULT_INVOICE_LAYOUT, "customer", "center"), "customer").x).toBe(26);
    expect(find(alignToPage(DEFAULT_INVOICE_LAYOUT, "customer", "right"), "customer").x).toBe(52);
    expect(find(alignToPage(DEFAULT_INVOICE_LAYOUT, "dates", "left"), "dates").x).toBe(0);
    expect(alignToPage(DEFAULT_INVOICE_LAYOUT, "lines", "right")).toBe(DEFAULT_INVOICE_LAYOUT);
  });

  it("knows what follows what", () => {
    expect([...descendants(DEFAULT_INVOICE_LAYOUT.blocks, "totals")].sort()).toEqual(
      ["instructions", "notes", "payments", "terms"].sort(),
    );
    expect(canFollow(DEFAULT_INVOICE_LAYOUT.blocks, "totals", "terms")).toBe(false);
    expect(canFollow(DEFAULT_INVOICE_LAYOUT.blocks, "terms", "totals")).toBe(true);
    expect(canFollow(DEFAULT_INVOICE_LAYOUT.blocks, "notes", "lines")).toBe(false);
    expect(canFollow(DEFAULT_INVOICE_LAYOUT.blocks, "notes", "notes")).toBe(false);
  });
});

describe("resolveTree", () => {
  const all = () => true;
  const keys = (nodes: { block: { key: string }; children: unknown[] }[]) =>
    nodes.map((node) => node.block.key);

  it("nests the followers under their block, zone by zone", () => {
    const [head, table, foot] = resolveTree(DEFAULT_INVOICE_LAYOUT.blocks, all);
    expect(keys(head!.nodes)).toEqual(["logo"]);
    expect(keys(head!.nodes[0]!.children)).toEqual(["issuer", "title"]);
    expect(keys(head!.nodes[0]!.children[0]!.children)).toEqual(["customer", "dates"]);
    expect(keys(table!.nodes)).toEqual(["lines"]);
    expect(keys(foot!.nodes)).toEqual(["totals"]);
    expect(keys(foot!.nodes[0]!.children[0]!.children[0]!.children)).toEqual(["notes"]);
  });

  it("lets a follower take the place of a block with nothing to show", () => {
    // No logo, no payments: the company name starts at the top, the how-to-pay block sits under the totals.
    const present = (key: InvoiceBlockId) => key !== "logo" && key !== "payments";
    const [head, , foot] = resolveTree(DEFAULT_INVOICE_LAYOUT.blocks, present);
    expect(keys(head!.nodes)).toEqual(["issuer", "title"]);
    expect(head!.nodes[0]!.y).toBe(0);
    expect(keys(foot!.nodes[0]!.children)).toEqual(["instructions"]);
    expect(foot!.nodes[0]!.children[0]!.y).toBe(20);
  });

  it("leaves out hidden blocks", () => {
    const layout = updateBlock(DEFAULT_INVOICE_LAYOUT, "notes", { show: false });
    const [, , foot] = resolveTree(layout.blocks, all);
    expect(keys(foot!.nodes[0]!.children[0]!.children[0]!.children)).toEqual(["terms"]);
  });
});
