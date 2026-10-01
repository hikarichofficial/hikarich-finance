import { Decimal, sumDecimals } from "@/domain/money/decimal";
import type {
  SalesPurchaseDimension,
  SalesPurchaseRow,
  SalesPurchaseSide,
  SavedReportRow,
} from "@/schemas/reports";

/**
 * Sales/Purchase report and Saved Reports (Step 09 §19, decision 252). The database computes every
 * figure (`sales_purchase_report`); these helpers parse the filters, total the rows exactly and build
 * saved-report links.
 */

export const SIDE_LABELS: Readonly<Record<SalesPurchaseSide, string>> = {
  sales: "Penjualan",
  purchases: "Pembelian",
};

export const DIMENSION_LABELS: Readonly<Record<SalesPurchaseDimension, string>> = {
  party: "Pelanggan / Pemasok",
  category: "Kategori",
  product: "Produk / Jasa",
  month: "Bulan",
};

export function dimensionOptions(side: SalesPurchaseSide): SalesPurchaseDimension[] {
  return side === "sales" ? ["party", "category", "product", "month"] : ["party", "category", "month"];
}

export function parseSide(value: string | undefined): SalesPurchaseSide {
  return value === "purchases" ? "purchases" : "sales";
}

export function parseDimension(
  value: string | undefined,
  side: SalesPurchaseSide,
): SalesPurchaseDimension {
  const options = dimensionOptions(side);
  return (options as string[]).includes(value ?? "") ? (value as SalesPurchaseDimension) : "party";
}

export function salesPurchaseTotals(rows: readonly SalesPurchaseRow[]): {
  documents: number;
  net: string;
  gross: string;
} {
  return {
    documents: rows.reduce((n, r) => n + r.document_count, 0),
    net: sumDecimals(rows.map((r) => Decimal.parse(r.net_amount))).toString(),
    gross: sumDecimals(rows.map((r) => Decimal.parse(r.gross_amount))).toString(),
  };
}

/** The query string to save for a report view: every filter except the Entity switcher's own `entity`. */
export function reportQueryToSave(
  params: Readonly<Record<string, string | string[] | undefined>>,
): string {
  const out = new URLSearchParams();
  for (const [key, value] of Object.entries(params)) {
    if (key === "entity" || value === undefined) continue;
    for (const v of Array.isArray(value) ? value : [value]) if (v !== "") out.append(key, v);
  }
  return out.toString().slice(0, 1000);
}

/** Opens a saved report in the active Entity. */
export function savedReportHref(
  row: Pick<SavedReportRow, "report_path" | "report_query">,
  entity: string | undefined,
): string {
  const params = new URLSearchParams(row.report_query);
  if (entity) params.set("entity", entity);
  const qs = params.toString();
  return qs ? `${row.report_path}?${qs}` : row.report_path;
}
