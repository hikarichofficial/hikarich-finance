import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { DashboardCashSection } from "@/services/dashboard/dashboard";
import type { ReconciliationStatusRow } from "@/schemas/money";
import { formatShortDate } from "./format";

function freshnessLabel(status: ReconciliationStatusRow | undefined): string {
  if (!status) return "Belum direkonsiliasi";
  if (status.session_in_progress) return "Sesi berjalan";
  if (status.unresolved_lines > 0) return `${status.unresolved_lines} baris belum selesai`;
  if (!status.last_reconciled_until) return "Belum pernah direkonsiliasi";
  return `Direkonsiliasi s.d. ${formatShortDate(status.last_reconciled_until)}`;
}

/** Account Snapshot (Step 09 §8, Step 10 §10): key bank/cash balances in their own currency, each with its
 * reconciliation freshness -- the same status `reconciliation_status` already computes, joined here purely
 * by `financial_account_id`, never recomputed. */
export function AccountSnapshot({
  cash,
  reconciliation,
}: {
  cash: DashboardCashSection | null;
  reconciliation: ReconciliationStatusRow[] | null;
}) {
  if (!cash) return null;
  const statusByAccount = new Map(reconciliation?.map((r) => [r.financial_account_id, r]) ?? []);
  const accounts = cash.accounts.filter((a) => a.is_active);

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Saldo Akun</h2>
        <Link className="dashboard-section-link" href="/money/accounts">
          Lihat semua
        </Link>
      </div>
      {accounts.length === 0 ? (
        <p className="dashboard-empty">Belum ada akun kas/bank aktif.</p>
      ) : (
        accounts.map((account) => (
          <div key={account.financial_account_id} className="account-row">
            <div>
              <div className="account-row-name">{account.name}</div>
              <div className="account-row-meta">
                {freshnessLabel(statusByAccount.get(account.financial_account_id))}
              </div>
            </div>
            <span className="account-row-balance">
              {formatMoney(account.movement_balance, account.currency)}
            </span>
          </div>
        ))
      )}
    </section>
  );
}
