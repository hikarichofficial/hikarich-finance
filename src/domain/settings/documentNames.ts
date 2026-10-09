/**
 * Which of the Entity's two names heads a financial document (OWNER, 9 October 2026; decision 391).
 *
 * A PT has a legal name and may trade under a brand name. An invoice already led with the legal name and put
 * the brand under it (decision 272); the payslip did not, and preferred the brand -- so a payslip, which is a
 * tax document, could go out under a trading name. The Entity now answers this once and every document that
 * carries its name follows the same answer.
 *
 * Nothing about an amount, a tax or an authorization depends on it; it decides two lines of a letterhead.
 */

export const DOCUMENT_NAME_STYLES = ["legal", "brand", "both"] as const;
export type DocumentNameStyle = (typeof DOCUMENT_NAME_STYLES)[number];

export const DOCUMENT_NAME_STYLE_LABELS: Record<DocumentNameStyle, string> = {
  legal: "Nama resmi saja",
  brand: "Nama brand saja",
  both: "Nama resmi, nama brand di bawahnya",
};

/** The default, and what an unreadable or missing setting falls back to: the behaviour invoices already had. */
export const DEFAULT_DOCUMENT_NAME_STYLE: DocumentNameStyle = "both";

/** Reads whatever came out of `entity_settings`, which is a jsonb value and so could be anything. */
export function documentNameStyle(value: unknown): DocumentNameStyle {
  return DOCUMENT_NAME_STYLES.includes(value as DocumentNameStyle)
    ? (value as DocumentNameStyle)
    : DEFAULT_DOCUMENT_NAME_STYLE;
}

export interface DocumentNames {
  primary: string;
  secondary: string | null;
}

/**
 * The one or two names to print. Whatever is chosen, a document is never left without a name: an Entity with
 * only one of the two shows that one, and the second line is dropped when it would repeat the first.
 */
export function documentNames(
  legalName: string | null | undefined,
  brandName: string | null | undefined,
  style: DocumentNameStyle,
): DocumentNames {
  const legal = legalName?.trim() || null;
  const brand = brandName?.trim() || null;

  if (style === "brand") return { primary: brand ?? legal ?? "", secondary: null };
  if (style === "legal") return { primary: legal ?? brand ?? "", secondary: null };

  const primary = legal ?? brand ?? "";
  return { primary, secondary: brand && brand !== primary ? brand : null };
}
