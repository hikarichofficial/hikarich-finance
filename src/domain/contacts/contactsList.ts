import type { ContactRow } from "@/schemas/contacts";

/**
 * Pure helpers for the Customers List/Detail (`/sales/customers`) and Vendors List/Detail
 * (`/purchases/vendors`) screens (P13, Step 09 §11/§12's own sitemap entries, Step 09 §9-§10 for the
 * shared List/Detail patterns). Both screens read the exact same `public.contacts` table, scoped by
 * `matchesContactRole` -- a contact recorded as `kind = 'both'` legitimately appears on both lists, never
 * duplicated or hidden, matching Step 02 §4's own "customer, vendor, both" model.
 */

export type ContactRole = "customer" | "vendor";

export function matchesContactRole(row: ContactRow, role: ContactRole): boolean {
  return row.kind === role || row.kind === "both";
}

export function listContactsByRole(rows: readonly ContactRow[], role: ContactRole): ContactRow[] {
  return rows.filter((row) => matchesContactRole(row, role));
}

export type ContactListFilter = "active" | "inactive";

export interface ContactFilterOption {
  value: ContactListFilter | null;
  label: string;
}

export const CONTACT_FILTER_OPTIONS: readonly ContactFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "active", label: "Aktif" },
  { value: "inactive", label: "Tidak Aktif" },
];

export function matchesContactFilter(row: ContactRow, filter: ContactListFilter | null): boolean {
  switch (filter) {
    case null:
      return true;
    case "active":
      return row.status === "active";
    case "inactive":
      return row.status === "inactive";
  }
}

export function parseContactFilter(value: string | undefined): ContactListFilter | undefined {
  const option = CONTACT_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesContactQuery(row: ContactRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.display_name).includes(needle) ||
    (row.legal_name ? normalize(row.legal_name).includes(needle) : false) ||
    (row.email ? normalize(row.email).includes(needle) : false) ||
    (row.phone ? normalize(row.phone).includes(needle) : false)
  );
}

export function filterContactRows(
  rows: readonly ContactRow[],
  filter: ContactListFilter | null,
  query: string,
): ContactRow[] {
  return rows.filter((row) => matchesContactFilter(row, filter) && matchesContactQuery(row, query));
}

export const CONTACT_ROLE_LABELS: Readonly<Record<ContactRole, string>> = {
  customer: "Pelanggan",
  vendor: "Vendor",
};

export const CONTACT_KIND_LABELS: Readonly<Record<ContactRow["kind"], string>> = {
  customer: "Pelanggan",
  vendor: "Vendor",
  both: "Pelanggan & Vendor",
};
