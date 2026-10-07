/**
 * The arrangement of the invoice document (decisions 310, 318, 319 and 321): which of its eleven blocks come where,
 * whether they are shown, how their text is aligned and sized, and where each one sits. There is no grid: every
 * block is free. The page has three zones from top to bottom (above the item table, the item table, below it). A
 * block is placed in a zone by its left edge `x` and width `w` (percent of the page width) and by `y` (pixels down
 * from the top of the zone), and may be given a minimum height `h` (pixels). A block can also "follow" another one of
 * the same zone (`after`): it then sits `y` pixels under the bottom of that block however tall it turns out to be,
 * so the company name stays under a logo of any size and the notes stay under a payment list of any length.
 * Presentation only: the six blocks that carry the invoice number, the parties, the dates, the lines and the amounts
 * can be moved but never hidden. The database holds the same rules (`app_private.valid_invoice_layout`); this module
 * is what the document and the editor read.
 */

export type InvoiceBlockId =
  | "logo"
  | "issuer"
  | "title"
  | "customer"
  | "dates"
  | "lines"
  | "totals"
  | "payments"
  | "instructions"
  | "notes"
  | "terms";

export type BlockAlign = "left" | "center" | "right";
export type BlockValign = "top" | "middle" | "bottom";
export type BlockSize = "xs" | "sm" | "md" | "lg" | "xl";
/** Above the item table, the item table itself, below it. */
export type BlockZone = "head" | "table" | "foot";

export const MIN_WIDTH = 8;
export const MAX_OFFSET = 600;
export const MAX_HEIGHT = 600;

/** How much larger or smaller the text (and the logo) of a block is drawn. */
export const SIZE_ZOOM: Record<BlockSize, number> = { xs: 0.8, sm: 0.9, md: 1, lg: 1.15, xl: 1.35 };
export const SIZE_LABEL: Record<BlockSize, string> = {
  xs: "Sangat kecil",
  sm: "Kecil",
  md: "Normal",
  lg: "Besar",
  xl: "Sangat besar",
};
export const SIZE_ORDER: readonly BlockSize[] = ["xs", "sm", "md", "lg", "xl"];

export interface InvoiceBlockSetting {
  key: InvoiceBlockId;
  show: boolean;
  /** How the text inside the block is aligned. */
  align: BlockAlign;
  /** Where the content sits inside the block when the block is taller than it needs to be. */
  valign: BlockValign;
  size: BlockSize;
  zone: BlockZone;
  /** Left edge, percent of the page width (0-100); `x + w` never passes 100. */
  x: number;
  /** Width, percent of the page width (8-100). */
  w: number;
  /** Pixels down from the top of the zone, or from the bottom of the block it follows. */
  y: number;
  /** Minimum height in pixels; 0 is "as tall as the content". */
  h: number;
  /** The block of the same zone this one sits under, if any. */
  after: InvoiceBlockId | null;
}

export interface InvoiceLayout {
  v: 2;
  blocks: InvoiceBlockSetting[];
}

interface BlockInfo {
  label: string;
  hint: string;
  /** Cannot be hidden: it carries a number, a party, a date or an amount. */
  required: boolean;
  /** The block always is the full width of the page in its own zone (the item table). */
  fixed: boolean;
  canAlign: boolean;
}

export const BLOCK_INFO: Record<InvoiceBlockId, BlockInfo> = {
  logo: {
    label: "Logo",
    hint: "Logo perusahaan",
    required: false,
    fixed: false,
    canAlign: true,
  },
  issuer: {
    label: "Nama & alamat perusahaan",
    hint: "Nama resmi, nama merek, alamat, kontak",
    required: true,
    fixed: false,
    canAlign: true,
  },
  title: {
    label: "Judul & nomor invoice",
    hint: "INVOICE, nomor, status",
    required: true,
    fixed: false,
    canAlign: true,
  },
  customer: {
    label: "Ditagihkan kepada",
    hint: "Nama dan alamat pelanggan",
    required: true,
    fixed: false,
    canAlign: true,
  },
  dates: {
    label: "Tanggal & mata uang",
    hint: "Tanggal invoice, jatuh tempo",
    required: true,
    fixed: false,
    canAlign: true,
  },
  lines: {
    label: "Tabel item",
    hint: "Deskripsi, jumlah, harga",
    required: true,
    fixed: true,
    canAlign: false,
  },
  totals: {
    label: "Total",
    hint: "Subtotal, pajak, total",
    required: true,
    fixed: false,
    canAlign: false,
  },
  payments: {
    label: "Pembayaran diterima",
    hint: "Daftar pembayaran dan kuitansi",
    required: false,
    fixed: false,
    canAlign: true,
  },
  instructions: {
    label: "Cara pembayaran",
    hint: "Rekening atau tombol Bayar sekarang",
    required: false,
    fixed: false,
    canAlign: true,
  },
  notes: {
    label: "Catatan",
    hint: "Catatan untuk pelanggan",
    required: false,
    fixed: false,
    canAlign: true,
  },
  terms: {
    label: "Syarat & ketentuan",
    hint: "Syarat pembayaran",
    required: false,
    fixed: false,
    canAlign: true,
  },
};

function block(
  key: InvoiceBlockId,
  zone: BlockZone,
  x: number,
  w: number,
  y: number,
  after: InvoiceBlockId | null,
  align: BlockAlign = "left",
): InvoiceBlockSetting {
  return { key, show: true, align, valign: "top", size: "md", zone, x, w, y, h: 0, after };
}

/** The standard arrangement: the logo, the company name under it and the invoice title at the right; the customer
 * on the left and the dates on the right; the item table; and under it the totals at the right, then the payments
 * received, how to pay, the notes and the terms, each one running the full width and following the one above it. */
export const DEFAULT_INVOICE_LAYOUT: InvoiceLayout = {
  v: 2,
  blocks: [
    block("logo", "head", 0, 22, 0, null),
    block("issuer", "head", 0, 52, 8, "logo"),
    block("title", "head", 60, 40, 8, "logo", "right"),
    block("customer", "head", 0, 48, 24, "issuer"),
    block("dates", "head", 52, 48, 24, "issuer", "right"),
    block("lines", "table", 0, 100, 0, null),
    block("totals", "foot", 56, 44, 0, null),
    block("payments", "foot", 0, 100, 20, "totals"),
    block("instructions", "foot", 0, 100, 14, "payments"),
    block("notes", "foot", 0, 100, 14, "instructions"),
    block("terms", "foot", 0, 100, 14, "notes"),
  ],
};

const IDS = DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => entry.key);
const ALIGNS: readonly string[] = ["left", "center", "right"];
const VALIGNS: readonly string[] = ["top", "middle", "bottom"];
const ZONES: readonly string[] = ["head", "table", "foot"];

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

function round1(value: number): number {
  return Math.round(value * 10) / 10;
}

function isId(value: unknown): value is InvoiceBlockId {
  return typeof value === "string" && (IDS as string[]).includes(value);
}

function standard(key: InvoiceBlockId): InvoiceBlockSetting {
  return { ...DEFAULT_INVOICE_LAYOUT.blocks.find((entry) => entry.key === key)! };
}

function cloneDefault(): InvoiceLayout {
  return { v: 2, blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => ({ ...entry })) };
}

/** The blocks that sit under this one, directly or through others that follow them. */
export function descendants(blocks: readonly InvoiceBlockSetting[], key: InvoiceBlockId) {
  const found = new Set<InvoiceBlockId>();
  let grew = true;
  while (grew) {
    grew = false;
    for (const entry of blocks) {
      if (
        entry.after !== null &&
        (entry.after === key || found.has(entry.after)) &&
        !found.has(entry.key)
      ) {
        found.add(entry.key);
        grew = true;
      }
    }
  }
  return found;
}

/** Whether `key` may follow `target`: not itself, not the item table, nothing that already follows `key`. */
export function canFollow(
  blocks: readonly InvoiceBlockSetting[],
  key: InvoiceBlockId,
  target: InvoiceBlockId,
): boolean {
  if (key === target || key === "lines" || target === "lines") return false;
  return !descendants(blocks, key).has(target);
}

/** Puts every value in range, cuts a "follows" chain that loops or points at the item table, and gives a block
 * that follows another one that other block's zone. The order of the blocks is kept (it is the stacking order). */
function normalize(blocks: InvoiceBlockSetting[]): InvoiceBlockSetting[] {
  const out = blocks.map((entry) => {
    const info = BLOCK_INFO[entry.key];
    if (info.fixed) {
      return {
        ...entry,
        show: true,
        zone: "table" as const,
        x: 0,
        w: 100,
        y: 0,
        h: 0,
        after: null,
      };
    }
    const w = clamp(round1(entry.w), MIN_WIDTH, 100);
    const x = clamp(round1(entry.x), 0, round1(100 - w));
    return {
      ...entry,
      show: info.required ? true : entry.show,
      zone: entry.zone === "table" ? ("foot" as const) : entry.zone,
      w,
      x,
      y: clamp(Math.round(entry.y), 0, MAX_OFFSET),
      h: clamp(Math.round(entry.h), 0, MAX_HEIGHT),
      after:
        entry.after !== null &&
        isId(entry.after) &&
        entry.after !== entry.key &&
        entry.after !== "lines"
          ? entry.after
          : null,
    };
  });
  const byKey = new Map(out.map((entry) => [entry.key, entry]));
  for (const entry of out) {
    if (entry.after && !byKey.has(entry.after)) entry.after = null;
  }
  for (const entry of out) {
    const seen = new Set<InvoiceBlockId>([entry.key]);
    let next = entry.after;
    while (next) {
      if (next === entry.key) {
        entry.after = null;
        break;
      }
      if (seen.has(next)) break;
      seen.add(next);
      next = byKey.get(next)?.after ?? null;
    }
  }
  const zoneOf = (key: InvoiceBlockId, depth = 0): BlockZone => {
    const entry = byKey.get(key)!;
    return entry.after && depth < IDS.length ? zoneOf(entry.after, depth + 1) : entry.zone;
  };
  return out.map((entry) => ({ ...entry, zone: zoneOf(entry.key) }));
}

function pick<T extends string>(value: unknown, allowed: readonly string[], fallback: T): T {
  return typeof value === "string" && allowed.includes(value) ? (value as T) : fallback;
}

function num(value: unknown, fallback: number): number {
  return typeof value === "number" && Number.isFinite(value) ? value : fallback;
}

/** A usable layout from whatever was stored: unknown or repeated blocks are dropped, a missing block is added back at
 * its standard place and a value out of range falls back to the standard. A layout saved on the old grid (version 1,
 * decisions 310-319) becomes the standard arrangement. Never throws. */
export function parseInvoiceLayout(value: unknown): InvoiceLayout {
  if (!value || typeof value !== "object" || Array.isArray(value)) return cloneDefault();
  const raw = value as { v?: unknown; blocks?: unknown };
  if (raw.v !== 2 || !Array.isArray(raw.blocks)) return cloneDefault();
  const seen = new Set<InvoiceBlockId>();
  const blocks: InvoiceBlockSetting[] = [];
  for (const item of raw.blocks) {
    if (!item || typeof item !== "object" || Array.isArray(item)) continue;
    const entry = item as Record<string, unknown>;
    if (!isId(entry.key) || seen.has(entry.key)) continue;
    seen.add(entry.key);
    const base = standard(entry.key);
    blocks.push({
      key: entry.key,
      show: typeof entry.show === "boolean" ? entry.show : base.show,
      align: pick(entry.align, ALIGNS, base.align),
      valign: pick(entry.valign, VALIGNS, base.valign),
      size: pick(entry.size, SIZE_ORDER, base.size),
      zone: pick(entry.zone, ZONES, base.zone),
      x: num(entry.x, base.x),
      w: num(entry.w, base.w),
      y: num(entry.y, base.y),
      h: num(entry.h, base.h),
      after: isId(entry.after) ? entry.after : null,
    });
  }
  for (const id of IDS) if (!seen.has(id)) blocks.push(standard(id));
  return { v: 2, blocks: normalize(blocks) };
}

/** The same layout with some settings of one block changed. */
export function updateBlock(
  layout: InvoiceLayout,
  key: InvoiceBlockId,
  patch: Partial<Omit<InvoiceBlockSetting, "key">>,
): InvoiceLayout {
  return {
    v: 2,
    blocks: normalize(
      layout.blocks.map((entry) => (entry.key === key ? { ...entry, ...patch } : entry)),
    ),
  };
}

/** Puts the block against the left edge, the middle or the right edge of the page, keeping its width. */
export function alignToPage(
  layout: InvoiceLayout,
  key: InvoiceBlockId,
  where: "left" | "center" | "right",
): InvoiceLayout {
  const me = layout.blocks.find((entry) => entry.key === key);
  if (!me || BLOCK_INFO[key].fixed) return layout;
  const x = where === "left" ? 0 : where === "right" ? 100 - me.w : (100 - me.w) / 2;
  return updateBlock(layout, key, { x });
}

/** Whether this is the standard arrangement (stored as "nothing set"). */
export function isDefaultLayout(layout: InvoiceLayout): boolean {
  return (
    JSON.stringify(parseInvoiceLayout(layout).blocks) ===
    JSON.stringify(DEFAULT_INVOICE_LAYOUT.blocks)
  );
}

/** A block on the page with the blocks that follow it. */
export interface LayoutNode {
  block: InvoiceBlockSetting;
  /** Pixels from the top of the zone (a root) or from the bottom of the parent. */
  y: number;
  children: LayoutNode[];
}

export interface LayoutZone {
  zone: BlockZone;
  nodes: LayoutNode[];
}

/** The tree the document draws: for every zone the blocks that are present, each with the ones that follow it. A
 * block with nothing to show (no logo, no notes...) takes no place, and what followed it takes its place: it keeps
 * the absent block's own offset and follows what the absent block followed. */
export function resolveTree(
  blocks: readonly InvoiceBlockSetting[],
  present: (key: InvoiceBlockId) => boolean,
): LayoutZone[] {
  const byKey = new Map(blocks.map((entry) => [entry.key, entry]));
  const here = (key: InvoiceBlockId) => {
    const entry = byKey.get(key);
    return Boolean(entry && entry.show && present(key));
  };
  const slot = (
    entry: InvoiceBlockSetting,
    depth = 0,
  ): { parent: InvoiceBlockId | null; y: number } => {
    if (!entry.after || depth > IDS.length) return { parent: null, y: entry.y };
    if (here(entry.after)) return { parent: entry.after, y: entry.y };
    const above = byKey.get(entry.after);
    return above ? slot(above, depth + 1) : { parent: null, y: entry.y };
  };
  const nodes = new Map<InvoiceBlockId, LayoutNode>();
  for (const entry of blocks) {
    if (here(entry.key)) nodes.set(entry.key, { block: entry, y: 0, children: [] });
  }
  const zones: LayoutZone[] = (["head", "table", "foot"] as const).map((zone) => ({
    zone,
    nodes: [],
  }));
  for (const entry of blocks) {
    const node = nodes.get(entry.key);
    if (!node) continue;
    const place = slot(entry);
    node.y = place.y;
    const parent = place.parent ? nodes.get(place.parent) : undefined;
    if (parent) parent.children.push(node);
    else zones.find((candidate) => candidate.zone === entry.zone)!.nodes.push(node);
  }
  return zones;
}
