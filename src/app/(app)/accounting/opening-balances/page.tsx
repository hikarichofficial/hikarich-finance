import Link from "next/link";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import {
  getEntityBaseCurrency,
  listJournals,
  listLedgerAccounts,
  listOpeningBatches,
} from "@/services/accounting/ledger";
import { openingEligibleAccounts } from "@/domain/accounting/openingBalances";
import { formatMoney } from "@/domain/money/format";
import { OpeningBalanceForm } from "@/features/accounting/OpeningBalanceForm";
import { CompleteOpeningForm } from "@/features/accounting/CompleteOpeningForm";

/**
 * Opening Balances (Step 09 §3 Accounting, Step 15 §24, decision 245). Viewing is gated `accounting.view`
 * (the `opening_balance_batches_select` RLS permission); posting and completing need `system.import`, the
 * permission both P3 RPCs check. Each batch links to the journal it posted (`source_type` `opening_balance`).
 */
export default async function OpeningBalancesPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("accounting.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const canPost = can(access, entityId, "system.import");

  const [batches, journals, accounts, baseCurrency] = await Promise.all([
    listOpeningBatches(entityId),
    listJournals(entityId),
    listLedgerAccounts(entityId),
    getEntityBaseCurrency(entityId),
  ]);
  const journalBySource = new Map(
    journals.filter((j) => j.source_type === "opening_balance").map((j) => [j.source_id, j.id]),
  );
  const completed = batches.some((b) => b.status === "completed");
  const hasPosted = batches.some((b) => b.status === "posted");
  const suffix = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Akuntansi</p>
          <h1>Saldo Awal</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${completed ? "success" : "progress"}`}>
            {completed ? "Selesai" : batches.length > 0 ? "Sedang diisi" : "Belum dimulai"}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Posting</h2>
        </div>
        {batches.length === 0 ? (
          <p>Belum ada saldo awal yang diposting untuk entitas ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal Cutover</th>
                <th scope="col">Status</th>
                <th scope="col">Catatan</th>
                <th scope="col" className="num">
                  Sisa Penampung
                </th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {batches.map((batch) => {
                const journalId = journalBySource.get(batch.id);
                return (
                  <tr key={batch.id}>
                    <td>{batch.cutover_date}</td>
                    <td data-label="Status">
                      <span
                        className={`status-badge status-badge-${batch.status === "completed" ? "success" : "progress"}`}
                      >
                        {batch.status === "completed" ? "Selesai" : "Diposting"}
                      </span>
                    </td>
                    <td data-label="Catatan">{batch.note ?? "—"}</td>
                    <td className="num" data-label="Sisa Penampung">
                      {batch.clearing_residual === null
                        ? "—"
                        : formatMoney(batch.clearing_residual, baseCurrency)}
                    </td>
                    <td data-label="Jurnal">
                      {journalId ? (
                        <Link href={`/accounting/journal/${journalId}${suffix}`}>Lihat jurnal</Link>
                      ) : (
                        "—"
                      )}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>

      {canPost && !completed ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Posting Saldo Awal</h2>
          </div>
          <OpeningBalanceForm
            accounts={openingEligibleAccounts(accounts)}
            baseCurrency={baseCurrency}
            entity={entity}
          />
        </section>
      ) : null}

      {canPost && !completed && hasPosted ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Selesaikan</h2>
          </div>
          <CompleteOpeningForm entity={entity} />
        </section>
      ) : null}
    </div>
  );
}
