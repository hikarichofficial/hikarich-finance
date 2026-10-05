import type { MoneyControlRow, ReconciliationStatusRow } from "@/schemas/money";

/**
 * Pure display helpers for the Reconciliation List screen (P13 unbuilt-screens backlog, Step 09 §13, Step 15
 * §8). `reconciliation_status` already returns one row per financial account with everything a read-only
 * status overview needs (`AccountsListScreen`'s own `accountListStatus` already consumes the same RPC for
 * its badge -- this file mirrors that priority order for a screen dedicated to reconciliation itself,
 * duplicated per this codebase's own `format.ts` precedent of keeping each feature folder self-contained
 * rather than sharing across features).
 */

export type ReconciliationListTone = "neutral" | "progress" | "attention" | "success";

export interface ReconciliationListStatus {
  text: string;
  tone: ReconciliationListTone;
}

export interface ReconciliationListRow extends ReconciliationStatusRow {
  currency: string;
}

/** `reconciliation_status` carries no currency of its own -- joined here by `financial_account_id` against
 * `money_control` (the same RPC `AccountsListScreen` already reads for its own rows), the same purely-
 * presentational join `mergeAccountRows`/`mergeTransferRows` already use rather than a second, currency-only
 * RPC call. An account missing from `control` is an archived one and is dropped. */
export function mergeReconciliationListRows(
  status: readonly ReconciliationStatusRow[],
  control: readonly MoneyControlRow[],
): ReconciliationListRow[] {
  const byId = new Map(control.map((row) => [row.financial_account_id, row.currency]));
  // `money_control` skips accounts removed with "Hapus Rekening" while `reconciliation_status` still lists
  // them, so a row without a control entry is an archived account and is left out (finding #91).
  return status
    .filter((row) => byId.has(row.financial_account_id))
    .map((row) => ({
      ...row,
      currency: byId.get(row.financial_account_id) ?? "IDR",
    }));
}

/** Sessions of accounts still on the list; archived accounts' sessions are hidden with them. */
export function visibleSessions<T extends { financial_account_id: string }>(
  sessions: readonly T[],
  control: readonly MoneyControlRow[],
): T[] {
  const live = new Set(control.map((row) => row.financial_account_id));
  return sessions.filter((s) => live.has(s.financial_account_id));
}

/** A session in progress is the most actionable state (someone is mid-way through); unresolved lines from a
 * completed session's own aftermath would not exist (a session cannot complete with unresolved lines -- see
 * `complete_reconciliation`), so `unresolved_lines > 0` in practice only ever co-occurs with
 * `session_in_progress`, kept as a defensive second check rather than assumed. */
export function reconciliationListStatus(row: ReconciliationStatusRow): ReconciliationListStatus {
  if (row.session_in_progress) return { text: "Sesi Berjalan", tone: "attention" };
  if (row.unresolved_lines > 0) {
    return { text: `${row.unresolved_lines} Baris Belum Selesai`, tone: "attention" };
  }
  if (!row.last_reconciled_until) return { text: "Belum Pernah Direkonsiliasi", tone: "progress" };
  return { text: "Direkonsiliasi", tone: "success" };
}
