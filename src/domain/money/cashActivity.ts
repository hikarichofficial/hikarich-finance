import type { MoneyControlRow, MoneyMovementRow } from "@/schemas/money";
import { sourceTypeLabel } from "./accountsList";

/**
 * Pure helpers for the Cash/Bank Activity screen (P13 Part 3c, Step 09 §13's fourth Money nav item): an
 * Entity-wide, chronological feed of every account's movements, distinct from Account Detail's own
 * single-account ledger (which has a running balance that only makes sense scoped to one account). Nothing
 * here calls the database: `mergeCashActivityRows` resolves each movement's account name/currency purely by
 * joining against `money_control`'s already-fetched rows, and its journal number against a separately-fetched
 * `Map` (see `getJournalNumbers`'s own doc comment on why that lookup can come back empty for some roles).
 */

export interface CashActivityRow extends MoneyMovementRow {
  account_name: string;
  account_currency: string;
  journal_number: string | null;
}

export function mergeCashActivityRows(
  movements: readonly MoneyMovementRow[],
  accounts: readonly MoneyControlRow[],
  journalNumbers: ReadonlyMap<string, string | null>,
): CashActivityRow[] {
  const accountsById = new Map(accounts.map((a) => [a.financial_account_id, a]));
  return movements.map((m) => {
    const account = accountsById.get(m.financial_account_id);
    return {
      ...m,
      account_name: account?.name ?? "Akun tidak dikenal",
      account_currency: account?.currency ?? m.currency,
      journal_number: journalNumbers.get(m.journal_id) ?? null,
    };
  });
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

/** `null` (the default) matches every account -- the same "no filter" meaning every other List screen uses. */
export function matchesAccountId(row: CashActivityRow, accountId: string | null): boolean {
  return accountId === null || row.financial_account_id === accountId;
}

export function matchesCashActivityQuery(row: CashActivityRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    normalize(row.account_name).includes(needle) ||
    normalize(sourceTypeLabel(row.source_type)).includes(needle) ||
    (row.description !== null && normalize(row.description).includes(needle)) ||
    (row.journal_number !== null && normalize(row.journal_number).includes(needle))
  );
}

export function filterCashActivityRows(
  rows: readonly CashActivityRow[],
  accountId: string | null,
  query: string,
): CashActivityRow[] {
  return rows.filter(
    (row) => matchesAccountId(row, accountId) && matchesCashActivityQuery(row, query),
  );
}
