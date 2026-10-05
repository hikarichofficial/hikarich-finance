import { formatMoney } from "@/domain/money/format";

/**
 * Indonesian text for one line of the tax-period reconciliation ("differences"). The database returns the
 * English sentence plus a machine `code`; the screen shows the code's own label as the title and this text as
 * the detail (finding #93: "No filing is recorded for this period" was shown untranslated). Numbers are read
 * back out of the database's sentence and shown in the entity currency.
 */
export function differenceDetailText(
  diff: { code: string; text: string; amount: string | null },
  currency: string,
): string {
  const numbers = [...diff.text.matchAll(/-?\d+(?:\.\d+)?/g)].map((m) => m[0]);
  const money = (n: string | undefined) => (n === undefined ? "" : formatMoney(n, currency));
  switch (diff.code) {
    case "filing_missing":
      return "Belum ada pelaporan yang dicatat untuk masa pajak ini.";
    case "filed_tax_differs":
      return `Pelaporan mencatat pajak ${money(numbers[0])}, sedangkan buku pajak mencatat ${money(numbers[1])}.`;
    case "filed_credit_differs":
      return `Pelaporan mengkreditkan PPN Masukan ${money(numbers[0])}, sedangkan buku pajak mencatat ${money(numbers[1])}.`;
    case "filed_base_differs":
      return `Pelaporan mencatat dasar pengenaan ${money(numbers[0])}, sedangkan penentuan pajak mencatat ${money(numbers[1])}.`;
    case "unpaid":
      return `${money(numbers[0])} dari pajak masa ini belum dibayar.`;
    case "overpaid":
      return `Pembayaran lebih besar ${money(numbers[0])} daripada yang tercatat di buku pajak.`;
    default:
      return diff.text;
  }
}
