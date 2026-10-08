/**
 * The tag that sorts a category of a Personal book for the personal income tax (decision 365). Plain module
 * (no "use client") so server pages and client forms can share the words.
 */
export const PERSONAL_TAX_ROLES = [
  "umkm_business",
  "freelance",
  "company_payout",
  "business_cost",
] as const;
export type PersonalTaxRole = (typeof PERSONAL_TAX_ROLES)[number];

export const PERSONAL_ROLE_LABELS: Readonly<Record<PersonalTaxRole, string>> = {
  umkm_business: "Penjualan usaha · PPh Final 0,5%",
  freelance: "Jasa & pekerjaan bebas · PPh progresif",
  company_payout: "Honor dari PT saya · otomatis dari PT",
  business_cost: "Biaya usaha & jasa · mengurangi penghasilan neto",
};

/** Which roles a category of this kind may carry; the database enforces the same pairing. */
export function personalRolesForKind(kind: string): PersonalTaxRole[] {
  if (kind === "revenue") return ["umkm_business", "freelance", "company_payout"];
  if (kind === "expense") return ["business_cost"];
  return [];
}

export function isPersonalTaxRole(value: string): value is PersonalTaxRole {
  return (PERSONAL_TAX_ROLES as readonly string[]).includes(value);
}

/** What the empty choice means for a kind of category. */
export function untaggedLabel(kind: string): string {
  return kind === "expense"
    ? "Pengeluaran pribadi · tidak mengurangi pajak"
    : "Pribadi · tidak dihitung pajak";
}
