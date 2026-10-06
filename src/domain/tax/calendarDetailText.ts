import { formatMoney } from "@/domain/money/format";

/**
 * Indonesian text for the `detail` of a Tax Calendar step. The database writes the English sentence
 * (`tax_calendar`, migrations p7/p9); the screen shows it translated, with the amount in the entity currency
 * and the filing date as the screen formats dates. A sentence this does not know is returned as it came.
 */
const FIXED: Readonly<Record<string, string>> = {
  "No deadline rule is in force for this period":
    "Belum ada aturan tenggat waktu yang berlaku untuk masa ini.",
  "The final tax of the month is computed": "PPh Final bulan ini sudah dihitung.",
  "Compute the final tax once the month has ended": "Hitung PPh Final setelah bulan berakhir.",
  "Nothing is recognised yet for this period": "Belum ada yang diakui untuk masa ini.",
  Paid: "Sudah dibayar.",
  "No tax was recognised for this period": "Tidak ada pajak yang diakui untuk masa ini.",
  Settled: "Sudah lunas.",
  "The return of the period is not recorded as filed":
    "SPT masa ini belum tercatat sudah dilaporkan.",
  "Attach the filing receipt as evidence": "Lampirkan bukti penerimaan pelaporan sebagai bukti.",
};

export function calendarDetailText(
  detail: string | null,
  currency: string,
  formatDate: (isoDate: string) => string = (d) => d,
): string {
  if (detail === null || detail === "") return "—";
  const fixed = FIXED[detail];
  if (fixed) return fixed;
  const toPay = /^(-?\d+(?:\.\d+)?) to pay by the deadline$/.exec(detail);
  if (toPay) return `${formatMoney(toPay[1], currency)} harus dibayar sebelum tenggat.`;
  const filed = /^Filed (\d{4}-\d{2}-\d{2}) \((.*)\)$/.exec(detail);
  if (filed) return `Sudah dilaporkan pada ${formatDate(filed[1])} (${filed[2]}).`;
  return detail;
}
