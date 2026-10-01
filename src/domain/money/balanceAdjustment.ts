import type { LedgerAccountRow } from "@/schemas/accounting";

/**
 * Pure helper for the Balance Adjustment form (P13 unbuilt-screens backlog, "Advanced Adjustments" nav item,
 * Step 09 §14, decision 232). `record_balance_adjustment` itself validates the counter account as active,
 * non-group, non-control, and never the opening-balance clearing account
 * (`20260922100000_p4_money_movements.sql`) -- this mirrors that exact check, nothing stricter (the RPC does
 * not require `allows_manual_posting`, so this filter does not add it either).
 */
export function eligibleCounterAccounts(accounts: readonly LedgerAccountRow[]): LedgerAccountRow[] {
  return accounts.filter(
    (account) =>
      account.status === "active" &&
      !account.is_group &&
      !account.is_control &&
      account.system_key !== "OPENING_BALANCE_CLEARING",
  );
}
