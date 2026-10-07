/**
 * The arrangement of the invoice document (decisions 310, 318 and 319): which of its eleven blocks come where,
 * whether they are shown, how their text is aligned and where each sits on a grid of twenty-four columns. The page
 * is a stack of rows (`row`, top to bottom). A row holds lanes side by side; a lane is a column of the page (a
 * starting column `col` and a width `span`) that holds one or more blocks stacked on top of each other (`stack`).
 * Lanes of a row never overlap, so the empty space under a short block (the company name beside a tall logo) can
 * take another block. Presentation only: the six blocks that carry the invoice number, the parties, the dates, the
 * lines and the amounts can be moved but never hidden. The database holds the same rules
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

/** The page is twenty-four columns wide. */
export const GRID_COLUMNS = 24;

/** A hidden block keeps this stack number so that showing it again puts it last in its lane. */
const HIDDEN_STACK = 99;

export interface InvoiceBlockSetting {
  key: InvoiceBlockId;
  show: boolean;
  /** How the text inside the block is aligned. */
  align: BlockAlign;
  /** First column of the lane (1-24). */
  col: number;
  /** Width of the lane in columns (1-24); `col + span - 1` never passes 24. */
  span: number;
  /** Row number, counted from 1 along the page; lanes with the same row are side by side. */
  row: number;
  /** Place within the lane, counted from 1 from the top: blocks of one lane are stacked. */
  stack: number;
}

export interface InvoiceLayout {
  v: 1;
  /** Columns of the grid; absent in layouts saved before decision 319 (twelve columns). */
  grid?: 24;
  blocks: InvoiceBlockSetting[];
  logo_size?: LogoSize;
}

interface BlockInfo {
  label: string;
  hint: string;
  /** Cannot be hidden: it carries a number, a party, a date or an amount. */
  required: boolean;
  /** The block always takes a whole row to itself (the item table). */
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
    fixedWidth: false,
    canAlign: false,
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
  stack = 1,
): InvoiceBlockSetting {
  return { key, show: true, align, col, span, row, stack };
}

/** The standard arrangement: the logo with the company name right beside it and the invoice title at the far
 * right; the customer on the left and the dates on the right; the items; and below them two columns, payments
 * received, notes and terms on the left, the totals and how to pay on the right. */
export const DEFAULT_INVOICE_LAYOUT: InvoiceLayout = {
  v: 1,
  grid: 24,
  logo_size: "md",
  blocks: [
    block("logo", 1, 1, 5),
    block("issuer", 1, 6, 11),
    block("title", 1, 17, 8, "right"),
    block("customer", 2, 1, 12),
    block("dates", 2, 13, 12),
    block("lines", 3, 1, 24),
    block("payments", 4, 1, 12, "left", 1),
    block("notes", 4, 1, 12, "left", 2),
    block("terms", 4, 1, 12, "left", 3),
    block("totals", 4, 13, 12, "left", 1),
    block("instructions", 4, 13, 12, "left", 2),
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
 * puts each block on the old twelve columns: neighbouring blocks that were not full width shared a row, a `fit`
 * block (the logo) takes two columns and the halves share the rest. */
function legacyPlacement(
  entries: { key: InvoiceBlockId; show: boolean; align: BlockAlign; width: string }[],
): {
  key: InvoiceBlockId;
  show: boolean;
  align: BlockAlign;
  col: number;
  span: number;
  row: number;
}[] {
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
  const out: {
    key: InvoiceBlockId;
    show: boolean;
    align: BlockAlign;
    col: number;
    span: number;
    row: number;
  }[] = [];
  rows.forEach((row, index) => {
    const fits = row.filter((entry) => entry.width === "fit").length;
    const halves = row.filter((entry) => entry.width === "half").length;
    const spare = 12 - 2 * fits;
    let col = 1;
    if (row.length === 1) {
      const only = row[0]!;
      const span = only.width === "full" ? 12 : only.width === "fit" ? 2 : 6;
      const start =
        span === 12
          ? 1
          : only.align === "right"
            ? 12 - span + 1
            : only.align === "center"
              ? Math.floor((12 - span) / 2) + 1
              : 1;
      out.push({
        key: only.key,
        show: only.show,
        align: only.align,
        col: start,
        span,
        row: index + 1,
      });
      return;
    }
    for (const entry of row) {
      const span = entry.width === "fit" ? 2 : Math.floor(spare / Math.max(1, halves));
      out.push({
        key: entry.key,
        show: entry.show,
        align: entry.align,
        col,
        span,
        row: index + 1,
      });
      col += span;
    }
  });
  return out;
}

/** Puts the blocks in order and in lanes: rows from top to bottom; in a row the lanes (blocks with the same columns)
 * from left to right, each lane's blocks from top to bottom. A lane that would overlap the lane before it moves to a
 * row of its own below; the item table keeps a row to itself. Rows and stack numbers are renumbered 1, 2, 3... */
function normalize(blocks: InvoiceBlockSetting[]): InvoiceBlockSetting[] {
  const sized = blocks.map((entry, index) => {
    if (BLOCK_INFO[entry.key].fixedWidth)
      return { entry: { ...entry, col: 1, span: GRID_COLUMNS }, index };
    const span = clamp(Math.round(entry.span), 1, GRID_COLUMNS);
    const col = clamp(Math.round(entry.col), 1, GRID_COLUMNS - span + 1);
    return { entry: { ...entry, col, span }, index };
  });
  const bySource = new Map<number, typeof sized>();
  for (const item of sized) {
    const list = bySource.get(item.entry.row) ?? [];
    list.push(item);
    bySource.set(item.entry.row, list);
  }
  const result: InvoiceBlockSetting[] = [];
  let row = 0;
  for (const source of [...bySource.keys()].sort((a, b) => a - b)) {
    const items = bySource.get(source)!;
    const shown = items.filter((item) => item.entry.show);
    const hiddenItems = items.filter((item) => !item.entry.show);
    const lanes = new Map<string, typeof sized>();
    for (const item of shown) {
      const key = `${item.entry.col}:${item.entry.span}`;
      const list = lanes.get(key) ?? [];
      list.push(item);
      lanes.set(key, list);
    }
    const ordered = [...lanes.values()].sort(
      (a, b) => a[0]!.entry.col - b[0]!.entry.col || b[0]!.entry.span - a[0]!.entry.span,
    );
    let end = 0;
    let open = false;
    const emit = (lane: typeof sized) => {
      lane
        .sort((a, b) => a.entry.stack - b.entry.stack || a.index - b.index)
        .forEach((item, at) => result.push({ ...item.entry, row, stack: at + 1 }));
    };
    for (const lane of ordered) {
      const first = lane[0]!.entry;
      if (!open || first.col <= end) {
        row += 1;
        end = 0;
        open = true;
      }
      emit(lane);
      end = Math.max(end, first.col + first.span - 1);
    }
    if (hiddenItems.length > 0) {
      if (!open) row += 1;
      for (const item of hiddenItems) result.push({ ...item.entry, row, stack: HIDDEN_STACK });
    }
  }
  return result;
}

function cloneDefault(): InvoiceLayout {
  return {
    v: 1,
    grid: 24,
    logo_size: DEFAULT_INVOICE_LAYOUT.logo_size,
    blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => ({ ...entry })),
  };
}

/** A usable layout from whatever was stored: unknown or repeated blocks are dropped, a missing block is added
 * back at the end, a value out of range falls back to the standard, and a layout stored before decision 319
 * (twelve columns, or `width` instead of `col`/`span`/`row`) is converted to the twenty-four column grid. Never
 * throws. */
export function parseInvoiceLayout(value: unknown): InvoiceLayout {
  if (!value || typeof value !== "object" || Array.isArray(value)) return cloneDefault();
  const raw = value as { blocks?: unknown; logo_size?: unknown; grid?: unknown };
  if (!Array.isArray(raw.blocks)) return cloneDefault();
  const standard = new Map(DEFAULT_INVOICE_LAYOUT.blocks.map((entry) => [entry.key, entry]));
  const seen = new Set<string>();
  const wide = raw.grid === 24;
  const columns = wide ? GRID_COLUMNS : 12;
  const entries: {
    key: InvoiceBlockId;
    show: boolean;
    align: BlockAlign;
    width: string;
    /** The alignment as stored, kept for the totals box of a twelve-column layout. */
    storedAlign?: BlockAlign;
    col?: number;
    span?: number;
    row?: number;
    stack?: number;
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
      ...(typeof entry.align === "string" && ALIGNS.includes(entry.align)
        ? { storedAlign: entry.align as BlockAlign }
        : {}),
      width:
        typeof entry.width === "string" && ["full", "half", "fit"].includes(entry.width)
          ? entry.width
          : "full",
      ...(isWhole(entry.col, 1, columns) ? { col: entry.col } : {}),
      ...(isWhole(entry.span, 1, columns) ? { span: entry.span } : {}),
      ...(isWhole(entry.row, 1, 200) ? { row: entry.row } : {}),
      ...(isWhole(entry.stack, 1, HIDDEN_STACK) ? { stack: entry.stack } : {}),
    });
  }
  const size =
    typeof raw.logo_size === "string" && SIZES.includes(raw.logo_size)
      ? (raw.logo_size as LogoSize)
      : "md";
  const placed = entries.every(
    (entry) => entry.col !== undefined && entry.span !== undefined && entry.row !== undefined,
  );
  let blocks: InvoiceBlockSetting[];
  if (placed) {
    blocks = entries.map((entry) => ({
      key: entry.key,
      show: entry.show,
      align: entry.align,
      col: entry.col!,
      span: entry.span!,
      row: entry.row!,
      stack: entry.stack ?? 1,
    }));
  } else {
    blocks = legacyPlacement(entries).map((entry) => ({ ...entry, stack: 1 }));
  }
  if (!wide) {
    // The twelve-column grid: every column becomes two. The totals box used to be a fixed-width block that
    // `align` pushed left, right or to the middle; it now keeps that place as a half-page lane.
    blocks = blocks.map((entry) => {
      const span = entry.span * 2;
      let col = entry.col * 2 - 1;
      if (entry.key === "totals") {
        const align = entries.find((other) => other.key === "totals")?.storedAlign ?? "right";
        return { ...entry, col: align === "left" ? 1 : align === "center" ? 7 : 13, span: 12 };
      }
      col = clamp(col, 1, GRID_COLUMNS - span + 1);
      return { ...entry, col, span };
    });
  }
  let nextRow = blocks.reduce((most, entry) => Math.max(most, entry.row), 0);
  for (const entry of DEFAULT_INVOICE_LAYOUT.blocks) {
    if (!seen.has(entry.key)) {
      nextRow += 1;
      blocks.push({
        ...entry,
        row: nextRow,
        col: BLOCK_INFO[entry.key].fixedWidth ? 1 : entry.col,
        stack: 1,
      });
    }
  }
  blocks = normalize(blocks);
  return { v: 1, grid: 24, logo_size: size, blocks };
}

/** True when the layout is the standard arrangement (so nothing needs to be stored). */
export function isDefaultLayout(layout: InvoiceLayout): boolean {
  return JSON.stringify(parseInvoiceLayout(layout)) === JSON.stringify(parseInvoiceLayout(null));
}

/** Changes one block's settings. A value the block does not allow is ignored; a block shown again joins the lane
 * of its old place at the end, or gets a row of its own when that place is taken. */
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

/** The shown blocks that share a lane with the block (the block itself included), from top to bottom. */
function laneOf(layout: InvoiceLayout, me: InvoiceBlockSetting): InvoiceBlockSetting[] {
  return layout.blocks
    .filter(
      (entry) =>
        entry.show && entry.row === me.row && entry.col === me.col && entry.span === me.span,
    )
    .sort((a, b) => a.stack - b.stack);
}

/** The columns a block's lane may start and end in without touching another lane of its row: `min` is the first
 * column it can start in, `max` the last it can end in. */
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
    if (other.col === me.col && other.span === me.span) continue;
    if (other.col + other.span - 1 < me.col) min = Math.max(min, other.col + other.span);
    else if (other.col > me.col + me.span - 1) max = Math.min(max, other.col - 1);
  }
  return { min, max };
}

/** Sets where a block's lane starts and how wide it is, kept inside the free space on its row; the blocks stacked in
 * the same lane move with it. The item table cannot be resized. */
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
  const mates = new Set(laneOf(layout, me).map((entry) => entry.key));
  return {
    ...layout,
    blocks: layout.blocks.map((entry) => (mates.has(entry.key) ? { ...entry, col, span } : entry)),
  };
}

/** Moves a block's lane so the free columns on both sides of it are equal (as near as the grid allows). */
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
  /** A new row of its own above or below row number `row`; `col` is where the block starts in it. */
  | { mode: "row"; at: "before" | "after"; row: number; col?: number }
  /** Stacked in the lane of `target`, above or below it. */
  | { mode: "stack"; at: "before" | "after"; target: InvoiceBlockId }
  /** A lane of its own in row number `row`, starting at `col`, where there is room. */
  | { mode: "lane"; row: number; col: number };

/** The room for a block's own lane in a row at a wanted column: the columns it can take (narrower than it was when
 * the gap is smaller), or null when the column is taken, the row holds the item table or the block is the table. */
export function laneRoom(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  row: number,
  col: number,
): { col: number; span: number } | null {
  const moving = layout.blocks.find((entry) => entry.key === id);
  if (!moving || BLOCK_INFO[id].fixedWidth) return null;
  const neighbours = layout.blocks.filter(
    (entry) => entry.show && entry.row === row && entry.key !== id,
  );
  if (neighbours.some((entry) => BLOCK_INFO[entry.key].fixedWidth)) return null;
  const want = clamp(col, 1, GRID_COLUMNS);
  if (neighbours.some((entry) => want >= entry.col && want <= entry.col + entry.span - 1)) {
    return null;
  }
  let low = 1;
  let high = GRID_COLUMNS;
  for (const entry of neighbours) {
    if (entry.col + entry.span - 1 < want) low = Math.max(low, entry.col + entry.span);
    else high = Math.min(high, entry.col - 1);
  }
  const span = clamp(moving.span, 1, high - low + 1);
  return { col: clamp(want, low, high - span + 1), span };
}

/** Moves a block by dropping it: above or below a row (a row of its own), onto a lane above or below one of its
 * blocks (stacked), or into a row at a column (a lane of its own). When the wanted columns are taken the block
 * gets a row of its own below. */
export function dropBlock(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  drop: DropTarget,
): InvoiceLayout {
  const moving = layout.blocks.find((entry) => entry.key === id);
  if (!moving) return layout;
  const rest = layout.blocks.filter((entry) => entry.key !== id);
  const fixed = BLOCK_INFO[id].fixedWidth;
  const ownRow = (row: number, col?: number): InvoiceLayout => {
    const span = fixed ? GRID_COLUMNS : moving.span;
    const start = fixed ? 1 : clamp(col ?? moving.col, 1, GRID_COLUMNS - span + 1);
    return {
      ...layout,
      blocks: normalize([...rest, { ...moving, row, col: start, span, stack: 1 }]),
    };
  };

  if (drop.mode === "row") {
    return ownRow(drop.row + (drop.at === "before" ? -0.5 : 0.5), drop.col);
  }

  if (drop.mode === "stack") {
    const target = rest.find((entry) => entry.key === drop.target);
    if (!target) return layout;
    const offset = drop.at === "before" ? -0.5 : 0.5;
    if (fixed || BLOCK_INFO[target.key].fixedWidth) return ownRow(target.row + offset);
    return {
      ...layout,
      blocks: normalize([
        ...rest,
        {
          ...moving,
          row: target.row,
          col: target.col,
          span: target.span,
          stack: target.stack + offset,
        },
      ]),
    };
  }

  const room = laneRoom(layout, id, drop.row, drop.col);
  if (!room) return ownRow(drop.row + 0.5, drop.col);
  return {
    ...layout,
    blocks: normalize([
      ...rest,
      { ...moving, row: drop.row, col: room.col, span: room.span, stack: 1 },
    ]),
  };
}

/** Moves a block one step up or down (for touch screens): past its neighbour in the lane, else out of the lane or
 * row into a row of its own, else past the neighbouring row. */
export function shiftRow(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  direction: "up" | "down",
): InvoiceLayout {
  const rows = layoutRows(layout);
  const at = rows.findIndex((row) =>
    row.lanes.some((lane) => lane.blocks.some((entry) => entry.key === id)),
  );
  if (at < 0) return layout;
  const row = rows[at]!;
  const lane = row.lanes.find((entry) => entry.blocks.some((other) => other.key === id))!;
  const position = lane.blocks.findIndex((entry) => entry.key === id);
  const up = direction === "up";
  const neighbour = lane.blocks[position + (up ? -1 : 1)];
  if (neighbour) {
    return dropBlock(layout, id, {
      mode: "stack",
      at: up ? "before" : "after",
      target: neighbour.key,
    });
  }
  const me = lane.blocks[position]!;
  if (lane.blocks.length > 1 || row.lanes.length > 1) {
    return dropBlock(layout, id, {
      mode: "row",
      at: up ? "before" : "after",
      row: row.row,
      col: me.col,
    });
  }
  const next = rows[at + (up ? -1 : 1)];
  if (!next) return layout;
  return dropBlock(layout, id, {
    mode: "row",
    at: up ? "before" : "after",
    row: next.row,
    col: me.col,
  });
}

export interface LayoutLane {
  col: number;
  span: number;
  /** From top to bottom. */
  blocks: InvoiceBlockSetting[];
}

export interface LayoutRow {
  /** The row number in the layout. */
  row: number;
  /** From left to right. */
  lanes: LayoutLane[];
}

/** The blocks that are shown, grouped into rows from top to bottom, each row into lanes from left to right and each
 * lane into blocks from top to bottom. */
export function layoutRows(layout: InvoiceLayout): LayoutRow[] {
  const rows: LayoutRow[] = [];
  const shown = layout.blocks
    .filter((entry) => entry.show)
    .sort((a, b) => a.row - b.row || a.col - b.col || b.span - a.span || a.stack - b.stack);
  for (const entry of shown) {
    let row = rows[rows.length - 1];
    if (!row || row.row !== entry.row) {
      row = { row: entry.row, lanes: [] };
      rows.push(row);
    }
    let lane = row.lanes[row.lanes.length - 1];
    if (!lane || lane.col !== entry.col || lane.span !== entry.span) {
      lane = { col: entry.col, span: entry.span, blocks: [] };
      row.lanes.push(lane);
    }
    lane.blocks.push(entry);
  }
  return rows;
}
