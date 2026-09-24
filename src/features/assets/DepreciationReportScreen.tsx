import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { depreciationLineStatusBadge } from "@/domain/assets/assetList";
import type { DepreciationRange } from "@/domain/assets/depreciationReport";
import type { DepreciationDueRow, DepreciationLineRow } from "@/schemas/assets";
import { formatMonth, formatShortDate } from "./format";

/**
 * Depreciation report (P13 Part 3f, fifth and final increment, Step 09 §9, §16; Step 12's report catalogue:
 * "Accounting Depreciation Schedule by asset/period"). Follows Step 09 §19's "filter bar + summary + table"
 * report pattern -- a date-range filter (`resolveDepreciationRange`, mirroring Cash/Bank Activity's own
 * `?from=`/`?to=`), a posted/scheduled totals summary, an attention band for months due but not yet posted
 * (`asset_depreciation_due`), and the schedule line table itself. One screen, not a route split like Other
 * Receivables/Payables (decision 176): the spec names Depreciation as a single nav item and a single report,
 * unlike its own separate "Other AR/AP" bullet.
 */
export function DepreciationReportScreen({
  rows,
  due,
  totals,
  range,
  query,
  currency,
  entity,
}: {
  rows: readonly DepreciationLineRow[];
  due: readonly DepreciationDueRow[];
  totals: { posted: string; scheduled: string };
  range: DepreciationRange;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Laporan Penyusutan</h1>
          <p className="list-screen-summary">{rows.length} baris jadwal ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Dari
            <input type="date" name="from" defaultValue={range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={range.to} />
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari kode atau nama aset…"
            aria-label="Cari baris penyusutan"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Total Terposting</dt>
            <dd>{formatMoney(totals.posted, currency)}</dd>
          </div>
          <div>
            <dt>Total Terjadwal</dt>
            <dd>{formatMoney(totals.scheduled, currency)}</dd>
          </div>
        </dl>
      </section>

      {due.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Perlu Diposting</h2>
          </div>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Aset</th>
                <th scope="col">Periode</th>
                <th scope="col">Batas Posting</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
              </tr>
            </thead>
            <tbody>
              {due.map((line) => (
                <tr key={`${line.asset_id}-${line.period_month}`}>
                  <td>{line.asset_code}</td>
                  <td>{formatMonth(line.period_month.slice(0, 7))}</td>
                  <td>{formatShortDate(line.journal_date)}</td>
                  <td className="num">{formatMoney(line.amount, currency)}</td>
                </tr>
              ))}
            </tbody>
          </table>
        </section>
      ) : null}

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada baris penyusutan pada rentang dan saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Aset</th>
              <th scope="col">Periode</th>
              <th scope="col">Status</th>
              <th scope="col">Jurnal</th>
              <th scope="col" className="num">
                Jumlah
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((line) => {
              const badge = depreciationLineStatusBadge(line.status);
              const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";
              const href = `/assets/${line.asset_id}${qs}`;
              return (
                <tr key={`${line.asset_id}-${line.period_month}-${line.plan_version}`}>
                  <td>
                    <Link href={href}>
                      {line.asset_code} · {line.asset_name}
                    </Link>
                  </td>
                  <td>{formatMonth(line.period_month.slice(0, 7))}</td>
                  <td>
                    <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
                  </td>
                  <td>
                    {line.journal_id ? (
                      <Link href={`/accounting/journal/${line.journal_id}${qs}`}>Lihat →</Link>
                    ) : (
                      "—"
                    )}
                  </td>
                  <td className="num">{formatMoney(line.amount, currency)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
