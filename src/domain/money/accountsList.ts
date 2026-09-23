import { Decimal } from "@/domain/money/decimal";
import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";

/**
 * Pure helpers for the Accounts List and Account Detail screens (P13 Part 3c, Step 09 §9-§10, §13). Nothing
 * here calls the database: `money_control` (balance + ledger difference) and `reconciliation_status`
 * (freshness) are two separate RPCs already established at Part 2 (`AccountSnapshot.tsx`'s own
 * `freshnessLabel`, reused here in a slightly fuller form since the List screen shows every account, not
 * just active ones with a KPI-card's worth of space); `mergeAccountRows` joins them purely by
 * `financial_account_id`, exactly like the Dashboard already does, never recomputing either RPC's numbers.
 */

export type AccountListTone = "neutral" | "progress" | "attention" | "success" | "critical";

export interface AccountListStatus {
  text: string;
  tone: AccountListTone;
}

export interface AccountListRow extends MoneyControlRow {
  reconciliation: ReconciliationStatusRow | null;
}

export function mergeAccountRows(
  control: readonly MoneyControlRow[],
  reconciliation: readonly ReconciliationStatusRow[],
): AccountListRow[] {
  const byId = new Map(reconciliation.map((r) => [r.financial_account_id, r]));
  return control.map((row) => ({
    ...row,
    reconciliation: byId.get(row.financial_account_id) ?? null,
  }));
}

/** The list/detail status badge: inactive first (nothing else matters once an account is retired), then a
 * ledger difference (the account's own system-vs-ledger control, always worth surfacing regardless of
 * reconciliation state), then reconciliation freshness in the same priority `AccountSnapshot` already uses. */
export function accountListStatus(row: AccountListRow): AccountListStatus {
  if (!row.is_active) return { text: "Tidak Aktif", tone: "neutral" };
  if (!Decimal.parse(row.difference).isZero()) {
    return { text: "Selisih dengan Buku Besar", tone: "critical" };
  }
  const r = row.reconciliation;
  if (r?.session_in_progress) return { text: "Sesi rekonsiliasi berjalan", tone: "attention" };
  if (r && r.unresolved_lines > 0) {
    return { text: `${r.unresolved_lines} baris belum selesai`, tone: "attention" };
  }
  if (!r || !r.last_reconciled_until)
    return { text: "Belum pernah direkonsiliasi", tone: "progress" };
  return { text: "Direkonsiliasi", tone: "success" };
}

export type AccountListFilter = "active" | "inactive" | "difference" | "unreconciled";

export interface AccountFilterOption {
  value: AccountListFilter | null;
  label: string;
}

export const ACCOUNT_FILTER_OPTIONS: readonly AccountFilterOption[] = [
  { value: null, label: "Semua" },
  { value: "active", label: "Aktif" },
  { value: "inactive", label: "Tidak Aktif" },
  { value: "difference", label: "Ada Selisih" },
  { value: "unreconciled", label: "Belum Direkonsiliasi" },
];

export function matchesAccountFilter(
  row: AccountListRow,
  filter: AccountListFilter | null,
): boolean {
  switch (filter) {
    case null:
      return true;
    case "active":
      return row.is_active;
    case "inactive":
      return !row.is_active;
    case "difference":
      return !Decimal.parse(row.difference).isZero();
    case "unreconciled":
      return !row.reconciliation?.last_reconciled_until;
  }
}

export function parseAccountFilter(value: string | undefined): AccountListFilter | undefined {
  const option = ACCOUNT_FILTER_OPTIONS.find((o) => o.value === value);
  return option?.value ?? undefined;
}

function normalize(text: string): string {
  return text.trim().toLowerCase();
}

export function matchesAccountQuery(row: AccountListRow, query: string): boolean {
  const needle = normalize(query);
  if (needle === "") return true;
  return normalize(row.name).includes(needle) || normalize(row.kind).includes(needle);
}

export function filterAccountRows(
  rows: readonly AccountListRow[],
  filter: AccountListFilter | null,
  query: string,
): AccountListRow[] {
  return rows.filter((row) => matchesAccountFilter(row, filter) && matchesAccountQuery(row, query));
}

/** A small label map for the source types this codebase's modules already record onto `money_movements`
 * (Sales/Purchases payments and refunds, Transfers, Tax payments, opening balances, manual corrections);
 * anything else (loans, assets, equity and other-obligations movements not yet given their own Part 3
 * screen) falls back to a plain, honest snake_case -> Title Case conversion rather than a guessed label. */
const SOURCE_TYPE_LABELS: Readonly<Record<string, string>> = {
  opening_balance: "Saldo Awal",
  transfer: "Transfer Antar Akun",
  payment: "Pembayaran Pelanggan",
  payment_credit: "Penerapan Saldo Lebih Pelanggan",
  refund: "Pengembalian Dana",
  vendor_payment: "Pembayaran Vendor",
  expense: "Pengeluaran",
  balance_adjustment: "Penyesuaian Saldo",
  tax_payment: "Pembayaran Pajak",
};

const ISO_DATE_PATTERN = /^\d{4}-\d{2}-\d{2}$/;

function toIsoDate(date: Date): string {
  return date.toISOString().slice(0, 10);
}

export interface AccountActivityRange {
  from: string;
  to: string;
}

/** Account Detail's ledger date-range filter (Step 09 §13: "filters, running balance"). `requestedFrom`/
 * `requestedTo` are the `?from=`/`?to=` query values, if any; an invalid, missing, or inverted (`from` after
 * `to`) pair falls back to a trailing 30-day window ending on `reference`'s UTC calendar date, mirroring
 * `resolveDashboardPeriod`'s own fallback shape. Pure and UTC-based, same reasoning as that helper: this only
 * picks the `account_activity` RPC's `p_from`/`p_to` arguments, never a notion of the Entity's own "today". */
export function resolveActivityRange(
  requestedFrom: string | undefined,
  requestedTo: string | undefined,
  reference: Date = new Date(),
): AccountActivityRange {
  const validFrom =
    requestedFrom && ISO_DATE_PATTERN.test(requestedFrom) ? requestedFrom : undefined;
  const validTo = requestedTo && ISO_DATE_PATTERN.test(requestedTo) ? requestedTo : undefined;
  if (validFrom && validTo && validFrom <= validTo) {
    return { from: validFrom, to: validTo };
  }
  const to = toIsoDate(reference);
  const from = toIsoDate(new Date(reference.getTime() - 29 * 24 * 60 * 60 * 1000));
  return { from, to };
}

export function sourceTypeLabel(sourceType: string): string {
  const known = SOURCE_TYPE_LABELS[sourceType];
  if (known) return known;
  return sourceType
    .split("_")
    .filter((part) => part.length > 0)
    .map((part) => part[0].toUpperCase() + part.slice(1))
    .join(" ");
}
