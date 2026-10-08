/**
 * What the taxes on a purchase mean for the company, in four numbers (OWNER, 8 October 2026: "di dalam card BARIS
 * harus juga memuat berapa pajaknya ... karena pajak juga terhitung sebagai pengeluaran perusahaan, dan pajak yang harus
 * dibayarkan harus masuk ringkasan"):
 *   - `vatCharged`: the VAT the vendor charged on the receipt (not a tax the company pays to the state),
 *   - `vatCreditable`: the part the company may credit against the VAT it reports (only a PKP company),
 *   - `vatCost`: the part that stays in the expense (a company that is not PKP, or VAT not creditable),
 *   - `withheld`: income tax held back from the payment and paid and reported by the company (PPh 23, 4(2), 26).
 * Display only: the figures come from the tax engine (a preview before recording, the recorded determinations after).
 */
export interface LineTaxSummary {
  vatCharged: string;
  vatCreditable: string;
  vatCost: string;
  withheld: string;
}

function amount(value: string | number): number {
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : 0;
}

function text(value: number): string {
  return value.toFixed(4);
}

/** Before the document is recorded: the engine's own preview totals. */
export function summaryFromPreview(
  taxTotal: string,
  preview: { vat_input_creditable: string; vat_input_cost: string; withheld_total: string },
): LineTaxSummary {
  return {
    vatCharged: taxTotal,
    vatCreditable: preview.vat_input_creditable,
    vatCost: preview.vat_input_cost,
    withheld: preview.withheld_total,
  };
}

/** After it is recorded: the determinations that are still in force (a superseded one is history). */
export function summaryFromDeterminations(
  taxTotal: string,
  rows: readonly { tax_kind: string; tax_amount: string; superseded_at: string | null }[],
): LineTaxSummary {
  const live = rows.filter((row) => row.superseded_at === null);
  const creditable = live
    .filter((row) => row.tax_kind === "vat_input")
    .reduce((sum, row) => sum + amount(row.tax_amount), 0);
  const withheld = live
    .filter((row) => row.tax_kind.startsWith("wht_"))
    .reduce((sum, row) => sum + amount(row.tax_amount), 0);
  const charged = amount(taxTotal);
  return {
    vatCharged: taxTotal,
    vatCreditable: text(creditable),
    vatCost: text(Math.max(charged - creditable, 0)),
    withheld: text(withheld),
  };
}
