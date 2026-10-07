/**
 * The arrangement of the invoice document (decisions 310 and 318): which of its eleven blocks come where, whether
 * they are shown, how their text is aligned and where each sits on a grid of twelve columns. A block has a `row`
 * (rows run top to bottom), a starting column `col` and a width in columns `span`; blocks that share a row sit side by
 * side and never overlap. Presentation only: the six blocks that carry the invoice number, the parties, the dates,
 * the lines and the amounts can be moved but never hidden. The database holds the same rules
 * (`app_private.valid_invoice_layout`); this module is what the document and the editor read.
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
export type LogoSize = "sm" | "md" | "lg";

/** The page is twelve columns wide. */
export const GRID_COLUMNS = 12;

export interface InvoiceBlockSetting {
  key: InvoiceBlockId;
  show: boolean;
  /** How the text inside the block is aligned. */
  align: BlockAlign;
  /** First column (1-12). */
  col: number;
  /** Width in columns (1-12); `col + span - 1` never passes 12. */
  span: number;
  /** Row number, counted from 1 along the page; blocks with the same row are side by side. */
  row: number;
}

export interface InvoiceLayout {
  v: 1;
  blocks: InvoiceBlockSetting[];
  logo_size?: LogoSize;
}

interface BlockInfo {
  label: string;
  hint: string;
  /** Cannot be hidden: it carries a number, a party, a date or an amount. */
  required: boolean;
  /** The block always takes the whole row (the item table and the totals box). */
  fixedWidth: boolean;
  canAlign: boolean;
}

export const BLOCK_INFO: Record<InvoiceBlockId, BlockInfo> = {
  logo: {
    label: "Logo",
    hint: "Logo perusahaan",
    required: false,
    fixedWidth: false,
    canAlign: true,
  },
  issuer: {
    label: "Nama & alamat perusahaan",
    hint: "Nama resmi, nama merek, alamat, kontak",
    required: true,
    fixedWidth: false,
    canAlign: true,
  },
  title: {
    label: "Judul & nomor invoice",
    hint: "INVOICE, nomor, status",
    required: true,
    fixedWidth: false,
    canAlign: true,
  },
  customer: {
    label: "Ditagihkan kepada",
    hint: "Nama dan alamat pelanggan",
    required: true,
    fixedWidth: false,
    canAlign: true,
  },
  dates: {
    label: "Tanggal & mata uang",
    hint: "Tanggal invoice, jatuh tempo",
    required: true,
    fixedWidth: false,
    canAlign: true,
  },
  lines: {
    label: "Tabel item",
    hint: "Deskripsi, jumlah, harga",
    required: true,
    fixedWidth: true,
    canAlign: false,
  },
  totals: {
    label: "Total",
    hint: "Subtotal, pajak, total",
    required: true,
    fixedWidth: true,
    canAlign: true,
  },
  payments: {
    label: "Pembayaran diterima",
    hint: "Daftar pembayaran dan kuitansi",
    required: false,
    fixedWidth: false,
    canAlign: true,
  },
  instructions: {
    label: "Cara pembayaran",
    hint: "Rekening atau tombol Bayar sekarang",
    required: false,
    fixedWidth: false,
    canAlign: true,
  },
  notes: {
    label: "Catatan",
    hint: "Catatan untuk pelanggan",
    required: false,
    fixedWidth: false,
    canAlign: true,
  },
  terms: {
    label: "Syarat & ketentuan",
    hint: "Syarat pembayaran",
    required: false,
    fixedWidth: false,
    canAlign: true,
  },
};

export const LOGO_SIZE_LABEL: Record<LogoSize, string> = { sm: "Kecil", md: "Sedang", lg: "Besar" };

function block(
  key: InvoiceBlockId,
  row: number,
  col: number,
  span: number,
  align: BlockAlign = "left",
): InvoiceBlockSetting {
  return { key, show: true, align, col, span, row };
}

/** The standard arrangement: the logo with the company name right beside it and the invoice title at the far
 * right, then the customer on the left and the dates on the right, the items, the totals flush right, and the rest. */
export const DEFAULT_INVOICE_LAYOUT: InvoiceLayout = {
  v: 1,
  logo_size: "md",
  blocks: [
    block("logo", 1, 1, 2),
    block("issuer", 1, 3, 6),
    block("title", 1, 9, 4, "right"),
    block("customer", 2, 1, 6),
    block("dates", 2, 7, 6),
    block("lines", 3, 1, 12),
    block("totals", 4, 1, 12, "right"),
    block("payments", 5, 1, 12),
    block("instructions", 6, 1, 12),
    block("notes", 7, 1, 12),
    block("terms", 8, 1, 12),
  ],
};

const IDS = DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => entry.key);
const ALIGNS: readonly string[] = ["left", "center", "right"];
const SIZES: readonly string[] = ["sm", "md", "lg"];

function clamp(value: number, low: number, high: number): number {
  return Math.max(low, Math.min(high, value));
}

function isWhole(value: unknown, low: number, high: number): value is number {
  return typeof value === "number" && Number.isInteger(value) && value >= low && value <= high;
}

/** Where a layout saved before the grid existed (decision 310: width `full`, `half` or, from decision 317, `fit`)
 * puts each block: neighbouring blocks that were not full width shared a row, a `fit` block (the logo) takes two
 * columns and the halves share the rest. */
function legacyPlacement(
  entries: { key: InvoiceBlockId; show: boolean; align: BlockAlign; width: string }[],
): InvoiceBlockSetting[] {
  const rows: (typeof entries)[] = [];
  let open: typeof entries | null = null;
  const share = (width: string) => (width === "half" ? 1 : 0);
  for (const entry of entries) {
    const joins =
      entry.show &&
      open !== null &&
      entry.width !== "full" &&
      open.length < 3 &&
      open.every((other) => other.width !== "full") &&
      open.reduce((sum, other) => sum + share(other.width), 0) < 2 &&
      open.reduce((sum, other) => sum + share(other.width), 0) + share(entry.width) <= 2;
    if (joins) {
      open!.push(entry);
    } else {
      open = entry.show ? [entry] : null;
      rows.push(open ?? [entry]);
    }
  }
  const out: InvoiceBlockSetting[] = [];
  rows.forEach((row, index) => {
    const fits = row.filter((entry) => entry.width === "fit").length;
    const halves = row.filter((entry) => entry.width === "half").length;
    const spare = GRID_COLUMNS - 2 * fits;
    let col = 1;
    if (row.length === 1) {
      const only = row[0]!;
      const span = only.width === "full" ? GRID_COLUMNS : only.width === "fit" ? 2 : 6;
      const start =
        span === GRID_COLUMNS
          ? 1
          : only.align === "right"
            ? GRID_COLUMNS - span + 1
            : only.align === "center"
              ? Math.floor((GRID_COLUMNS - span) / 2) + 1
              : 1;
      out.push({ ...only, col: start, span, row: index + 1 });
      return;
    }
    for (const entry of row) {
      const span = entry.width === "fit" ? 2 : Math.floor(spare / Math.max(1, halves));
      out.push({ ...entry, col, span, row: index + 1 });
      col += span;
    }
  });
  return out.map(({ key, show, align, col, span, row }) => ({ key, show, align, col, span, row }));
}

/** Puts blocks in order (row, then column), makes sure no two shown blocks of a row overlap (the later one moves to
 * a row of its own), keeps the full-width blocks full width and renumbers the rows 1, 2, 3... */
function normalize(blocks: InvoiceBlockSetting[]): InvoiceBlockSetting[] {
  const fixed = blocks.map((entry) => {
    if (BLOCK_INFO[entry.key].fixedWidth) return { ...entry, col: 1, span: GRID_COLUMNS };
    const span = clamp(Math.round(entry.span), 1, GRID_COLUMNS);
    const col = clamp(Math.round(entry.col), 1, GRID_COLUMNS - span + 1);
    return { ...entry, col, span };
  });
  const sorted = fixed
    .map((entry, index) => ({ entry, index }))
    .sort((a, b) => a.entry.row - b.entry.row || a.entry.col - b.entry.col || a.index - b.index)
    .map(({ entry }) => entry);
  const result: InvoiceBlockSetting[] = [];
  let row = 0;
  let sourceRow: number | null = null;
  let end = 0;
  for (const entry of sorted) {
    if (entry.row !== sourceRow) {
      row += 1;
      sourceRow = entry.row;
      end = 0;
    } else if (entry.show && entry.col <= end) {
      row += 1;
      end = 0;
    }
    result.push({ ...entry, row });
    if (entry.show) end = Math.max(end, entry.col + entry.span - 1);
  }
  return result;
}

function cloneDefault(): InvoiceLayout {
  return {
    v: 1,
    logo_size: DEFAULT_INVOICE_LAYOUT.logo_size,
    blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => ({ ...entry })),
  };
}

/** A usable layout from whatever was stored: unknown or repeated blocks are dropped, a missing block is added
 * back at the end, a value out of range falls back to the standard, and a layout stored before the grid existed
 * (with `width` instead of `col`/`span`/`row`) is converted. Never throws. */
export function parseInvoiceLayout(value: unknown): InvoiceLayout {
  if (!value || typeof value !== "object" || Array.isArray(value)) return cloneDefault();
  const raw = value as { blocks?: unknown; logo_size?: unknown };
  if (!Array.isArray(raw.blocks)) return cloneDefault();
  const standard = new Map(DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => [entry.key, entry]));
  const seen = new Set<string>();
  const entries: {
    key: InvoiceBlockId;
    show: boolean;
    align: BlockAlign;
    width: string;
    col?: number;
    span?: number;
    row?: number;
  }[] = [];
  for (const item of raw.blocks) {
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    const id = entry.key;
    if (typeof id !== "string" || !IDS.includes(id as InvoiceBlockId) || seen.has(id)) continue;
    seen.add(id);
    const base = standard.get(id as InvoiceBlockId)!;
    const info = BLOCK_INFO[id as InvoiceBlockId];
    entries.push({
      key: id as InvoiceBlockId,
      show: info.required ? true : entry.show !== false,
      align:
        info.canAlign && typeof entry.align === "string" && ALIGNS.includes(entry.align)
          ? (entry.align as BlockAlign)
          : base.align,
      width:
        typeof entry.width === "string" && ["full", "half", "fit"].includes(entry.width)
          ? entry.width
          : "full",
      ...(isWhole(entry.col, 1, GRID_COLUMNS) ? { col: entry.col } : {}),
      ...(isWhole(entry.span, 1, GRID_COLUMNS) ? { span: entry.span } : {}),
      ...(isWhole(entry.row, 1, 200) ? { row: entry.row } : {}),
    });
  }
  const size =
    typeof raw.logo_size === "string" && SIZES.includes(raw.logo_size)
      ? (raw.logo_size as LogoSize)
      : "md";
  const placed = entries.every(
    (entry) => entry.col !== undefined && entry.span !== undefined && entry.row !== undefined,
  );
  let blocks: InvoiceBlockSetting[] = placed
    ? entries.map((entry) => ({
        key: entry.key,
        show: entry.show,
        align: entry.align,
        col: entry.col!,
        span: entry.span!,
        row: entry.row!,
      }))
    : legacyPlacement(entries);
  let nextRow = blocks.reduce((most, entry) => Math.max(most, entry.row), 0);
  for (const entry of DEFAULT_INVOICE_LAYOUT.blocks) {
    if (!seen.has(entry.key)) {
      nextRow += 1;
      blocks.push({ ...entry, row: nextRow });
    }
  }
  blocks = normalize(blocks);
  return { v: 1, logo_size: size, blocks };
}

/** True when the layout is the standard arrangement (so nothing needs to be stored). */
export function isDefaultLayout(layout: InvoiceLayout): boolean {
  return JSON.stringify(parseInvoiceLayout(layout)) === JSON.stringify(parseInvoiceLayout(null));
}

/** Changes one block's settings. A value the block does not allow is ignored, and showing a block again moves it to
 * a row of its own when its old place is taken. */
export function updateBlock(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  change: Partial<Pick<InvoiceBlockSetting, "show" | "align">>,
): InvoiceLayout {
  const info = BLOCK_INFO[id];
  return {
    ...layout,
    blocks: normalize(
      layout.blocks.map((entry) => {
        if (entry.key !== id) return entry;
        return {
          ...entry,
          show: change.show !== undefined && !info.required ? change.show : entry.show,
          align: change.align !== undefined && info.canAlign ? change.align : entry.align,
        };
      }),
    ),
  };
}

/** The columns a block may start and end in without touching a neighbour on its row: `min` is the first column
 * it can start in, `max` the last it can end in. */
export function placementBounds(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
): { min: number; max: number } {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me) return { min: 1, max: GRID_COLUMNS };
  let min = 1;
  let max = GRID_COLUMNS;
  for (const other of layout.blocks) {
    if (other.key === id || !other.show || other.row !== me.row) continue;
    if (other.col + other.span - 1 < me.col) min = Math.max(min, other.col + other.span);
    else if (other.col > me.col + me.span - 1) max = Math.min(max, other.col - 1);
  }
  return { min, max };
}

/** Sets where a block starts and how wide it is, kept inside the free space on its row. The item table and the
 * totals box cannot be resized. */
export function setPlacement(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  change: { col?: number; span?: number },
): InvoiceLayout {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me || BLOCK_INFO[id].fixedWidth) return layout;
  const { min, max } = placementBounds(layout, id);
  const span = clamp(Math.round(change.span ?? me.span), 1, max - min + 1);
  const col = clamp(Math.round(change.col ?? me.col), min, max - span + 1);
  return {
    ...layout,
    blocks: layout.blocks.map((entry) => (entry.key === id ? { ...entry, col, span } : entry)),
  };
}

/** Moves a block so the free columns on both sides of it are equal (as near as the grid allows). */
export function centerBlock(layout: InvoiceLayout, id: InvoiceBlockId): InvoiceLayout {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me || BLOCK_INFO[id].fixedWidth) return layout;
  const { min, max } = placementBounds(layout, id);
  const col = min + Math.floor((max - min + 1 - me.span) / 2);
  return setPlacement(layout, id, { col });
}

/** Free columns left and right of a block on the page, for the balance readout of the ruler. */
export function pageMargins(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
): { left: number; right: number } {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me) return { left: 0, right: 0 };
  return { left: me.col - 1, right: GRID_COLUMNS - (me.col + me.span - 1) };
}

export type DropTarget =
  /** A new row of its own above or below the row of `target`; `col` is where the block starts in it. */
  | { mode: "before" | "after"; target: InvoiceBlockId; col?: number }
  /** Into the row of `target`, starting at `col`, where there is room. */
  | { mode: "into"; target: InvoiceBlockId; col: number };

/** Moves a block by dropping it: above or below a row, or into a row at a column. When the wanted columns are
 * taken the block is made narrower to fit the gap; when there is no gap at all it gets a row of its own below. */
export function dropBlock(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  drop: DropTarget,
): InvoiceLayout {
  const moving = layout.blocks.find((entry) => entry.key === id);
  const target = layout.blocks.find((entry) => entry.key === drop.target);
  if (!moving || !target || moving.key === target.key) return layout;
  const rest = layout.blocks.filter((entry) => entry.key !== id);
  const fixed = BLOCK_INFO[id].fixedWidth;
  const startAt = (span: number, col: number | undefined) =>
    fixed ? 1 : clamp(col ?? moving.col, 1, GRID_COLUMNS - span + 1);

  const alone = (row: number): InvoiceBlockSetting => {
    const span = fixed ? GRID_COLUMNS : moving.span;
    return {
      ...moving,
      row,
      span,
      col: startAt(span, drop.col),
    };
  };

  if (drop.mode !== "into") {
    const row = target.row + (drop.mode === "before" ? -0.5 : 0.5);
    return { ...layout, blocks: normalize([...rest, alone(row)]) };
  }

  const neighbours = rest.filter(
    (entry) => entry.show && entry.row === target.row && entry.key !== id,
  );
  const takenFixed = neighbours.some((entry) => BLOCK_INFO[entry.key].fixedWidth);
  if (fixed || takenFixed) {
    return { ...layout, blocks: normalize([...rest, alone(target.row + 0.5)]) };
  }
  const covers = (entry: InvoiceBlockSetting, column: number) =>
    column >= entry.col && column <= entry.col + entry.span - 1;
  const want = clamp(drop.col, 1, GRID_COLUMNS);
  if (neighbours.some((entry) => covers(entry, want))) {
    // The column is taken: fall back to a row of its own below.
    return { ...layout, blocks: normalize([...rest, alone(target.row + 0.5)]) };
  }
  let low = 1;
  let high = GRID_COLUMNS;
  for (const entry of neighbours) {
    if (entry.col + entry.span - 1 < want) low = Math.max(low, entry.col + entry.span);
    else high = Math.min(high, entry.col - 1);
  }
  const span = clamp(moving.span, 1, high - low + 1);
  const col = clamp(want, low, high - span + 1);
  return {
    ...layout,
    blocks: normalize([...rest, { ...moving, row: target.row, col, span }]),
  };
}

/** Moves a block one row up or down (for touch screens): a block that shares its row first gets a row of its own,
 * a block that is alone swaps places with the neighbouring row. */
export function shiftRow(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  direction: "up" | "down",
): InvoiceLayout {
  const me = layout.blocks.find((entry) => entry.key === id);
  if (!me) return layout;
  const sharing = layout.blocks.filter(
    (entry) => entry.show && entry.row === me.row && entry.key !== id,
  );
  if (sharing.length > 0) {
    return dropBlock(layout, id, {
      mode: direction === "up" ? "before" : "after",
      target: sharing[0]!.key,
      col: me.col,
    });
  }
  const rows = layoutRows(layout);
  const at = rows.findIndex((row) => row.some((entry) => entry.key === id));
  const next = rows[at + (direction === "up" ? -1 : 1)];
  if (!next) return layout;
  return dropBlock(layout, id, {
    mode: direction === "up" ? "before" : "after",
    target: next[0]!.key,
    col: me.col,
  });
}

/** The blocks that are shown, grouped into rows from top to bottom, each row from left to right. */
export function layoutRows(layout: InvoiceLayout): InvoiceBlockSetting[][] {
  const rows: InvoiceBlockSetting[][] = [];
  let current: number | null = null;
  for (const entry of layout.blocks) {
    if (!entry.show) continue;
    if (entry.row !== current) {
      rows.push([]);
      current = entry.row;
    }
    rows[rows.length - 1]!.push(entry);
  }
  return rows;
}
