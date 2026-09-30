import Link from "next/link";
import { periodStatusDisplay } from "@/domain/accounting/periodsList";
import type { AccountingPeriodRow, PeriodCheck } from "@/schemas/accounting";
import { PeriodActions, type PeriodActionPermissions } from "./PeriodActions";
import { formatShortDate } from "./format";

/**
 * Accounting Period Close Detail (P13, Step 09 §14: "Period Close screen presents a checklist of
 * blockers/warnings before Close"). `checks` is `period_close_checks`' own result -- every blocker/warning
 * this period currently carries, always fetched (not only when in `closing_review`) so a person can see
 * what would block closing before even starting the review, matching the spec's own "before Close" wording
 * rather than only showing it mid-workflow.
 */
export function PeriodCloseScreen({
  period,
  checks,
  backHref,
  permissions,
}: {
  period: AccountingPeriodRow;
  checks: readonly PeriodCheck[];
  backHref: string;
  permissions: PeriodActionPermissions;
}) {
  const status = periodStatusDisplay(period.status);
  const blockers = checks.filter((c) => c.severity === "blocker");
  const warnings = checks.filter((c) => c.severity === "warning");

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar periode</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Periode Akuntansi · Tahun Fiskal {period.fiscal_year}
          </p>
          <h1>
            {formatShortDate(period.period_start)} – {formatShortDate(period.period_end)}
          </h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Mulai</dt>
            <dd>{formatShortDate(period.period_start)}</dd>
          </div>
          <div>
            <dt>Berakhir</dt>
            <dd>{formatShortDate(period.period_end)}</dd>
          </div>
          <div>
            <dt>Ditutup Pada</dt>
            <dd>{period.closed_at ? formatShortDate(period.closed_at.slice(0, 10)) : "—"}</dd>
          </div>
          {period.reopened_at ? (
            <>
              <div>
                <dt>Dibuka Kembali Pada</dt>
                <dd>{formatShortDate(period.reopened_at.slice(0, 10))}</dd>
              </div>
              <div>
                <dt>Alasan Dibuka Kembali</dt>
                <dd>{period.reopen_reason ?? "—"}</dd>
              </div>
            </>
          ) : null}
        </dl>
        <PeriodActions periodId={period.id} status={period.status} permissions={permissions} />
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Daftar Periksa Penutupan</h2>
        </div>
        {checks.length === 0 ? (
          <p className="dashboard-empty">Tidak ada pemblokir atau peringatan untuk periode ini.</p>
        ) : (
          <ul className="dashboard-list">
            {[...blockers, ...warnings].map((check) => (
              <li key={check.code} className="dashboard-list-item">
                <div>
                  <p className="dashboard-list-item-title">{check.message}</p>
                  <p className="dashboard-list-item-detail">{check.item_count} item</p>
                </div>
                <div className="dashboard-list-item-end">
                  <span
                    className={`status-badge status-badge-${
                      check.severity === "blocker" ? "critical" : "attention"
                    }`}
                  >
                    {check.severity === "blocker" ? "Pemblokir" : "Peringatan"}
                  </span>
                </div>
              </li>
            ))}
          </ul>
        )}
      </section>
    </div>
  );
}
