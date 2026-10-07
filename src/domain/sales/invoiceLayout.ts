/**
 * The arrangement of the invoice document (decision 310): which of its eleven blocks come where, whether they
 * are shown, how they are aligned and whether they take the full width, half of it or just their own width. Presentation only: the
 * six blocks that carry the invoice number, the parties, the dates, the lines and the amounts can be moved but
 * never hidden. The database holds the same rules (`app_private.valid_invoice_layout`); this module is what the
 * document and the editor read.
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
/** `full` takes the whole row, `half` shares it, `fit` is only as wide as its content (a logo beside the name). */
export type BlockWidth = "full" | "half" | "fit";
export type LogoSize = "sm" | "md" | "lg";

export interface InvoiceBlockSetting {
  key: InvoiceBlockId;
  show: boolean;
  align: BlockAlign;
  width: BlockWidth;
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
  /** The block has a fixed shape: it can only be moved (the item table) or aligned (the totals). */
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

/** The standard arrangement: the logo with the company name right beside it and the invoice title at the far
 * right, then the customer on the left and the dates on the right, the items, the totals flush right, and the rest. */
export const DEFAULT_INVOICE_LAYOUT: InvoiceLayout = {
  v: 1,
  logo_size: "md",
  blocks: [
    { key: "logo", show: true, align: "left", width: "fit" },
    { key: "issuer", show: true, align: "left", width: "half" },
    { key: "title", show: true, align: "right", width: "half" },
    { key: "customer", show: true, align: "left", width: "half" },
    { key: "dates", show: true, align: "left", width: "half" },
    { key: "lines", show: true, align: "left", width: "full" },
    { key: "totals", show: true, align: "right", width: "full" },
    { key: "payments", show: true, align: "left", width: "full" },
    { key: "instructions", show: true, align: "left", width: "full" },
    { key: "notes", show: true, align: "left", width: "full" },
    { key: "terms", show: true, align: "left", width: "full" },
  ],
};

const IDS = DEFAULT_INVOICE_LAYOUT.blocks.map((block) => block.key);
const ALIGNS: readonly string[] = ["left", "center", "right"];
const WIDTHS: readonly string[] = ["full", "half", "fit"];
const SIZES: readonly string[] = ["sm", "md", "lg"];

function cloneDefault(): InvoiceLayout {
  return {
    v: 1,
    logo_size: DEFAULT_INVOICE_LAYOUT.logo_size,
    blocks: DEFAULT_INVOICE_LAYOUT.blocks.map((block) => ({ ...block })),
  };
}

/** A usable layout from whatever was stored: unknown or repeated blocks are dropped, a missing block is added
 * back at its standard place, and a value out of range falls back to the standard. Never throws. */
export function parseInvoiceLayout(value: unknown): InvoiceLayout {
  if (!value || typeof value !== "object" || Array.isArray(value)) return cloneDefault();
  const raw = value as { blocks?: unknown; logo_size?: unknown };
  if (!Array.isArray(raw.blocks)) return cloneDefault();
  const standard = new Map(DEFAULT_INVOICE_LAYOUT.blocks.map((block) => [block.key, block]));
  const seen = new Set<string>();
  const blocks: InvoiceBlockSetting[] = [];
  for (const item of raw.blocks) {
    if (!item || typeof item !== "object") continue;
    const entry = item as Record<string, unknown>;
    const id = entry.key;
    if (typeof id !== "string" || !IDS.includes(id as InvoiceBlockId) || seen.has(id)) continue;
    seen.add(id);
    const base = standard.get(id as InvoiceBlockId)!;
    const info = BLOCK_INFO[id as InvoiceBlockId];
    blocks.push({
      key: id as InvoiceBlockId,
      show: info.required ? true : entry.show !== false,
      align:
        info.canAlign && typeof entry.align === "string" && ALIGNS.includes(entry.align)
          ? (entry.align as BlockAlign)
          : base.align,
      width:
        !info.fixedWidth && typeof entry.width === "string" && WIDTHS.includes(entry.width)
          ? (entry.width as BlockWidth)
          : base.width,
    });
  }
  for (const block of DEFAULT_INVOICE_LAYOUT.blocks) {
    if (!seen.has(block.key)) blocks.push({ ...block });
  }
  const size =
    typeof raw.logo_size === "string" && SIZES.includes(raw.logo_size)
      ? (raw.logo_size as LogoSize)
      : "md";
  return { v: 1, logo_size: size, blocks };
}

/** True when the layout is the standard arrangement (so nothing needs to be stored). */
export function isDefaultLayout(layout: InvoiceLayout): boolean {
  return JSON.stringify(parseInvoiceLayout(layout)) === JSON.stringify(DEFAULT_INVOICE_LAYOUT);
}

/** Moves a block so it lands at `toIndex` of the list (0-based, after it has been taken out). */
export function moveBlock(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  toIndex: number,
): InvoiceLayout {
  const from = layout.blocks.findIndex((block) => block.key === id);
  if (from < 0) return layout;
  const blocks = layout.blocks.slice();
  const [item] = blocks.splice(from, 1);
  const at = Math.max(0, Math.min(blocks.length, toIndex));
  blocks.splice(at, 0, item!);
  return { ...layout, blocks };
}

/** Changes one block's settings. A value the block does not allow is ignored. */
export function updateBlock(
  layout: InvoiceLayout,
  id: InvoiceBlockId,
  change: Partial<Pick<InvoiceBlockSetting, "show" | "align" | "width">>,
): InvoiceLayout {
  const info = BLOCK_INFO[id];
  return {
    ...layout,
    blocks: layout.blocks.map((block) => {
      if (block.key !== id) return block;
      return {
        ...block,
        show: change.show !== undefined && !info.required ? change.show : block.show,
        align: change.align !== undefined && info.canAlign ? change.align : block.align,
        width: change.width !== undefined && !info.fixedWidth ? change.width : block.width,
      };
    }),
  };
}

/** How much of a row a block takes: a `fit` block none worth counting, a `half` block one share of two. */
function rowShare(block: InvoiceBlockSetting): number {
  return block.width === "half" ? 1 : 0;
}

/** The blocks that are shown, grouped into rows: neighbouring blocks that are not full width share a row until
 * the row holds two halves (or three blocks), so a logo (`fit`), the company (`half`) and the title (`half`) sit in
 * one line; every other block has a row of its own. */
export function layoutRows(layout: InvoiceLayout): InvoiceBlockSetting[][] {
  const shown = layout.blocks.filter((block) => block.show);
  const rows: InvoiceBlockSetting[][] = [];
  for (const block of shown) {
    const row = rows[rows.length - 1];
    const joins =
      row !== undefined &&
      block.width !== "full" &&
      row.length < 3 &&
      row.every((other) => other.width !== "full") &&
      row.reduce((sum, other) => sum + rowShare(other), 0) < 2 &&
      row.reduce((sum, other) => sum + rowShare(other), 0) + rowShare(block) <= 2;
    if (joins) row.push(block);
    else rows.push([block]);
  }
  return rows;
}
