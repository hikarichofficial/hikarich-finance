/** Plain module (no "use client"): a server page importing this constant from a client component module
 * would get an unusable client reference, so the Kategori table showed the raw stored word (finding #104). */
export const CATEGORY_KIND_LABELS: Readonly<Record<string, string>> = {
  revenue: "Pendapatan",
  expense: "Beban",
  asset: "Aset",
  liability: "Kewajiban",
  equity: "Modal",
  other: "Lainnya",
};
