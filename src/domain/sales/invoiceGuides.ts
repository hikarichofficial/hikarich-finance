import { BLOCK_INFO, GRID_COLUMNS, type InvoiceBlockId, type InvoiceLayout } from "./invoiceLayout";

/** Which part of the block lines up: its left edge, its right edge or its middle. */
export type GuideEdge = "left" | "right" | "center";

/** A line the editor draws while a block is moved or resized (like the smart guides of Canva): where the block's
 * edge or middle lines up with the page or with another block. `at` counts columns from the left edge of the page
 * (0 to 24). */
export interface AlignmentGuide {
  edge: GuideEdge;
  at: number;
  label: string;
}

/** The places where the block's left edge, right edge or middle is exactly in line with the page (its left edge,
 * its right edge, its middle) or with a block of another lane, so the owner can see at a glance that it is centred
 * or lined up. Blocks of the lane the block stands in are skipped: they line up with it by definition. */
export function alignmentGuides(layout: InvoiceLayout, id: InvoiceBlockId): AlignmentGuide[] {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me || !me.show) return [];
  const left = me.col - 1;
  const right = me.col - 1 + me.span;
  const middle = left + me.span / 2;
  const found = new Map<string, AlignmentGuide>();
  const add = (edge: GuideEdge, at: number, label: string) => {
    const key = `${edge}:${at}`;
    const old = found.get(key);
    if (!old) found.set(key, { edge, at, label });
    else if (!old.label.startsWith("Tepi") && !old.label.startsWith("Tepat")) {
      old.label = `${old.label}, ${label.replace(/^(Rata kiri|Rata kanan|Sejajar tengah) dengan /, "")}`;
    }
  };
  if (middle === GRID_COLUMNS / 2) add("center", middle, "Tepat di tengah halaman");
  if (left === 0) add("left", 0, "Tepi kiri halaman");
  if (right === GRID_COLUMNS) add("right", GRID_COLUMNS, "Tepi kanan halaman");
  for (const other of layout.blocks) {
    if (other.key === id || !other.show) continue;
    if (other.row === me.row && other.col === me.col && other.span === me.span) continue;
    if (BLOCK_INFO[other.key].fixedWidth) continue;
    const name = BLOCK_INFO[other.key].label;
    const otherLeft = other.col - 1;
    const otherRight = other.col - 1 + other.span;
    const otherMiddle = otherLeft + other.span / 2;
    if (left === otherLeft && left !== 0) add("left", left, `Rata kiri dengan ${name}`);
    if (right === otherRight && right !== GRID_COLUMNS)
      add("right", right, `Rata kanan dengan ${name}`);
    if (middle === otherMiddle && middle !== GRID_COLUMNS / 2) {
      add("center", middle, `Sejajar tengah dengan ${name}`);
    }
  }
  return [...found.values()].slice(0, 6);
}
