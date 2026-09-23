import type { MoneyControlRow, TransferRow } from "@/schemas/money";

/**
 * Pure helpers for the Transfers List and Transfer Detail screens (P13 Part 3c, Step 09 §9-§10, §13). Nothing
 * here calls the database: `mergeTransferRows` resolves each transfer's `from_account_id`/`to_account_id`
 * into a display name purely by joining against `money_control`'s already-fetched rows (the same account list
 * the Accounts List/the Transfer create form already read), never a second query.
 */

export type TransferListTone = "neutral" | "attention" | "success";

export interface TransferListStatus {
  text: string;
  tone: TransferListTone;
}

export interface TransferListRow extends TransferRow {
  from_account_name: string;
  from_account_currency: string;
  to_account_name: string;
  to_account_currency: string;
}

/** `amount_out`/`amount_in` are each in their own side's account currency (never assumed to be the Entity's
 * base or IDR), so the account lookup resolves currency alongside the display name. An account not found in
 * the given list (a stale id, or the caller only passed active accounts) falls back to the Entity's own
 * `entities.base_currency` would require an extra query this merge deliberately avoids -- "IDR" is used only
 * as this codebase's own default currency (every account created so far is IDR; Step 03's currency list
 * starts there), never presented as fabricated data since the account name already flags it as unresolved. */
function resolveAccount(
  accounts: ReadonlyMap<string, MoneyControlRow>,
  accountId: string,
): { name: string; currency: string } {
  const found = accounts.get(accountId);
  return found
    ? { name: found.name, currency: found.currency }
    : { name: "Akun tidak dikenal", currency: "IDR" };
}

export function mergeTransferRows(
  transfers: readonly TransferRow[],
  accounts: readonly MoneyControlRow[],
): TransferListRow[] {
  const byId = new Map(accounts.map((a) => [a.financial_account_id, a]));
  return transfers.map((t) => {
    const from = resolveAccount(byId, t.from_account_id);
    const to = resolveAccount(byId, t.to_account_id);
    return {
      ...t,
      from_account_name: from.name,
      from_account_currency: from.currency,
      to_account_name: to.name,
      to_account_currency: to.currency,
    };
  });
}

/** The list/detail status badge, matching `BILL_STATUS_LABELS`/`EXPENSE_STATUS_LABELS`'s own tone
 * convention: a pending maker-checker state is `attention`, a settled/terminal state is `neutral`, and only
 * the confirmed (posted) state itself is `success`. */
export function transferListStatus(row: TransferRow): TransferListStatus {
  switch (row.status) {
    case "draft":
      return { text: "Menunggu Konfirmasi", tone: "attention" };
    case "confirmed":
      return { text: "Terkonfirmasi", tone: "success" };
    case "cancelled":
      return { text: "Dibatalkan", tone: "neutral" };
    case "reversed":
      return { text: "Dibalik", tone: "neutral" };
  }
}

export type TransferListFilter = "draft" | "confirmed" | "cancelled" | "reversed";

export interface TransferFilterOption {
  value: TransferListFilter | null;
  label: string;
}

export const TRANSFER_FILTER_OPTIONS: readonly TransferFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "draft", label: "Menunggu Konfirmasi" },
  { value: "confirmed", label: "Terkonfirmasi" },
  { value: "cancelled", label: "Dibatalkan" },
  { value: "reversed", label: "Dibalik" },
];

export function matchesTransferFilter(
  row: TransferRow,
  filter: TransferListFilter | null,
): boolean {
  return filter === null || row.status === filter;
}

export function parseTransferFilter(value: string | undefined): TransferListFilter | undefined {
  const option = TRANSFER_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesTransferQuery(row: TransferListRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return (
    (row.transfer_number !== null && normalize(row.transfer_number).includes(needle)) ||
    normalize(row.from_account_name).includes(needle) ||
    normalize(row.to_account_name).includes(needle) ||
    (row.description !== null && normalize(row.description).includes(needle)) ||
    (row.reference !== null && normalize(row.reference).includes(needle))
  );
}

export function filterTransferRows(
  rows: readonly TransferListRow[],
  filter: TransferListFilter | null,
  query: string,
): TransferListRow[] {
  return rows.filter(
    (row) => matchesTransferFilter(row, filter) && matchesTransferQuery(row, query),
  );
}

export interface TransferActivityEntry {
  label: string;
  date: string | null;
  tone: TransferListTone;
}

/** Transfer Detail's Activity area (Step 09 §10), built from the transfer row's own workflow timestamps
 * (`created_at`, `confirmed_at`, `cancelled_at`, `reversed_at`/`reverse_reason`) -- the direct read already
 * carries these, so nothing is fabricated. */
export function transferActivityTimeline(transfer: TransferRow): TransferActivityEntry[] {
  const entries: TransferActivityEntry[] = [
    { label: "Draf dibuat", date: transfer.created_at, tone: "neutral" },
  ];
  if (transfer.confirmed_at) {
    entries.push({ label: "Dikonfirmasi", date: transfer.confirmed_at, tone: "success" });
  }
  if (transfer.cancelled_at) {
    entries.push({ label: "Dibatalkan", date: transfer.cancelled_at, tone: "neutral" });
  }
  if (transfer.reversed_at) {
    entries.push({
      label: transfer.reverse_reason ? `Dibalik: ${transfer.reverse_reason}` : "Dibalik",
      date: transfer.reversed_at,
      tone: "neutral",
    });
  }
  return entries;
}
