import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  ASSET_SOURCE_LABELS,
  assetConditionBadge,
  assetEventDisplay,
  assetStatusBadge,
  depreciationLineStatusBadge,
} from "@/domain/assets/assetList";
import { DEPRECIATION_METHOD_LABELS, DISPOSAL_TYPE_LABELS } from "@/domain/assets/assets";
import type { AssetDetail } from "@/schemas/assets";
import { formatMonth, formatShortDate } from "./format";

/**
 * Asset Detail (P13 Part 3f, first increment, Step 09 §10, §16: "asset detail, acquisition source,
 * depreciation, documents and lifecycle"). `asset_detail` already returns the schedule and the event log
 * together with the asset's own fields, so -- like Journal Detail (decision 172) -- this follows the narrower
 * "Standard Record Detail Pattern subset" (Header / Summary / Schedule / Activity, plus Disposal when present)
 * rather than the full pattern with a separate placeholder section: an asset's depreciation schedule and
 * lifecycle events already ARE its detail. Document attachment (the spec's "documents") is deferred; nothing
 * in the P8 RPC surface reads or writes one yet.
 */
export function AssetDetailScreen({
  detail,
  currency,
  entity,
  backHref,
}: {
  detail: AssetDetail;
  currency: string;
  entity: string | undefined;
  backHref: string;
}) {
  const { asset, schedule, events, disposal } = detail;
  const statusBadge = assetStatusBadge(asset.status);
  const conditionBadge = assetConditionBadge(asset.condition);
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar aset</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Aset · {ASSET_SOURCE_LABELS[asset.source_type]}</p>
          <h1>{asset.name}</h1>
          <p className="record-detail-counterparty">{asset.code}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
          <span className={`status-badge status-badge-${conditionBadge.tone}`}>
            {conditionBadge.text}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Tanggal Perolehan</dt>
            <dd>{formatShortDate(asset.acquisition_date)}</dd>
          </div>
          <div>
            <dt>Mulai Dipakai</dt>
            <dd>{asset.in_service_date ? formatShortDate(asset.in_service_date) : "—"}</dd>
          </div>
          <div>
            <dt>Lokasi</dt>
            <dd>{asset.location ?? "—"}</dd>
          </div>
          <div>
            <dt>Penanggung Jawab</dt>
            <dd>{asset.custodian ?? "—"}</dd>
          </div>
          <div>
            <dt>Biaya Perolehan</dt>
            <dd>{formatMoney(asset.acquisition_cost, currency)}</dd>
          </div>
          <div>
            <dt>Akumulasi Penyusutan</dt>
            <dd>{formatMoney(asset.accumulated, currency)}</dd>
          </div>
          <div>
            <dt>Nilai Buku</dt>
            <dd>{formatMoney(asset.net_book_value, currency)}</dd>
          </div>
          <div>
            <dt>Metode Penyusutan</dt>
            <dd>
              {asset.depreciation_method
                ? DEPRECIATION_METHOD_LABELS[asset.depreciation_method]
                : "—"}
            </dd>
          </div>
          {asset.useful_life_months !== null ? (
            <div>
              <dt>Umur Manfaat</dt>
              <dd>{asset.useful_life_months} bulan</dd>
            </div>
          ) : null}
          {asset.residual_value !== null ? (
            <div>
              <dt>Nilai Sisa</dt>
              <dd>{formatMoney(asset.residual_value, currency)}</dd>
            </div>
          ) : null}
          {asset.fiscal_class_key ? (
            <div>
              <dt>Golongan Fiskal</dt>
              <dd>{asset.fiscal_class_key}</dd>
            </div>
          ) : null}
          {asset.serial_number ? (
            <div>
              <dt>Nomor Seri</dt>
              <dd>{asset.serial_number}</dd>
            </div>
          ) : null}
          {asset.cancel_reason ? (
            <div>
              <dt>Alasan Dibatalkan</dt>
              <dd>{asset.cancel_reason}</dd>
            </div>
          ) : null}
        </dl>
        {asset.description ? <p className="hint">{asset.description}</p> : null}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Jadwal Penyusutan</h2>
        </div>
        {schedule.length === 0 ? (
          <p className="dashboard-empty">Belum ada jadwal penyusutan.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Bulan</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Status</th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {schedule.map((line) => {
                const lineBadge = depreciationLineStatusBadge(line.status);
                return (
                  <tr key={line.id}>
                    <td>{formatMonth(line.month)}</td>
                    <td className="num">{formatMoney(line.amount, currency)}</td>
                    <td>
                      <span className={`status-badge status-badge-${lineBadge.tone}`}>
                        {lineBadge.text}
                      </span>
                    </td>
                    <td>
                      {line.journal_id ? (
                        <Link href={`/accounting/journal/${line.journal_id}${qs}`}>Lihat →</Link>
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

      {disposal ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Pelepasan</h2>
          </div>
          <dl className="record-summary-grid">
            <div>
              <dt>Jenis</dt>
              <dd>{DISPOSAL_TYPE_LABELS[disposal.type]}</dd>
            </div>
            <div>
              <dt>Tanggal</dt>
              <dd>{formatShortDate(disposal.date)}</dd>
            </div>
            <div>
              <dt>Hasil Pelepasan</dt>
              <dd>{formatMoney(disposal.proceeds, currency)}</dd>
            </div>
            <div>
              <dt>Laba/Rugi Pelepasan</dt>
              <dd>{formatMoney(disposal.gain_loss, currency)}</dd>
            </div>
            {disposal.journal_id ? (
              <div>
                <dt>Jurnal</dt>
                <dd>
                  <Link href={`/accounting/journal/${disposal.journal_id}${qs}`}>Lihat →</Link>
                </dd>
              </div>
            ) : null}
          </dl>
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        {events.length === 0 ? (
          <p className="dashboard-empty">Belum ada aktivitas.</p>
        ) : (
          <ul className="record-activity-list">
            {events.map((event, index) => {
              const display = assetEventDisplay(event.type);
              return (
                <li key={`${event.type}-${index}`} className="record-activity-item">
                  <span className={`status-badge status-badge-${display.tone}`}>
                    {display.text}
                  </span>
                  <span className="record-activity-date">{formatShortDate(event.date)}</span>
                </li>
              );
            })}
          </ul>
        )}
      </section>
    </div>
  );
}
