import type { LedgerAccountRow } from "@/schemas/accounting";

/**
 * Pure helper for the Balance Adjustment form (P13 unbuilt-screens backlog, "Advanced Adjustments" nav item,
 * Step 09 §14, decision 232). `record_balance_adjustment` itself validates the counter account as active,
 * non-group, non-control, and never the opening-balance clearing account
 * (`20260922100000_p4_money_movements.sql`) -- this mirrors that exact check, nothing stricter (the RPC does
 * not require `allows_manual_posting`, so this filter does not add it either).
 *
 * P46 adds the one rule that is about tax, not about accounting: an adjustment may never book income (revenue,
 * revenue reductions, other income). The tax base is built from invoices, settlements and "Catat Pendapatan",
 * never from a free journal, so income booked here would reach the books but not the tax. The RPC refuses it
 * too; this keeps those accounts out of the choice so nobody meets the refusal.
 */
export const INCOME_ACCOUNT_CLASSES: readonly string[] = [
  "revenue",
  "contra_revenue",
  "other_income",
];

export function eligibleCounterAccounts(accounts: readonly LedgerAccountRow[]): LedgerAccountRow[] {
  return accounts.filter(
    (account) =>
      account.status === "active" &&
      !account.is_group &&
      !account.is_control &&
      account.system_key !== "OPENING_BALANCE_CLEARING" &&
      !INCOME_ACCOUNT_CLASSES.includes(account.account_class),
  );
}
