import type { SearchResultRow } from "@/schemas/search";

/**
 * Maps a Global Search result to its detail route (P13 Part 6, Step 09 §6/§7: "Find: invoke Global
 * Search results directly"). Seven of the nine indexed kinds already have a shipped Detail screen; two --
 * `contact` and `expense` -- do not (DECISIONS: Sales/Purchases screens still remaining after Part 3a/3b,
 * "Customers, Products & Services"/"Expenses, Vendors" are still open). `null` marks those two as
 * not-yet-navigable so the caller can render them as a plain, non-clickable result instead of a link that
 * 404s -- the same choice already made elsewhere in this codebase for a known, scoped gap (e.g. decision
 * 168's "Vendor" text fallback) rather than guessing at a route that does not exist.
 */
export function searchResultHref(
  row: Pick<SearchResultRow, "target_type" | "target_id">,
): string | null {
  switch (row.target_type) {
    case "invoice":
      return `/sales/invoices/${row.target_id}`;
    case "bill":
      return `/purchases/bills/${row.target_id}`;
    case "fixed_asset":
      return `/assets/${row.target_id}`;
    case "loan":
      return `/assets/loans/${row.target_id}`;
    case "other_obligation":
      return `/assets/obligations/${row.target_id}`;
    case "equity_event":
      return `/assets/equity/${row.target_id}`;
    case "journal_entry":
      return `/accounting/journal/${row.target_id}`;
    case "product":
      return `/sales/products/${row.target_id}`;
    case "contact":
    case "expense":
      return null;
  }
}
