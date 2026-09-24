import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  LOAN_DIRECTION_LABELS,
  LOAN_METHOD_LABELS,
  type LoanMethod,
} from "@/domain/financing/financing";
import {
  LOAN_PAYMENT_KIND_LABELS,
  loanPaymentStatusBadge,
  loanScheduleStateBadge,
  loanStatusBadge,
  loanVersionStatusBadge,
  type LoanPaymentKind,
  type LoanVersionStatus,
} from "@/domain/financing/loanList";
import type { LoanDetail, LoanScheduleRow } from "@/schemas/financing";
import { formatShortDate } from "./format";

const SOURCE_TYPE_LABELS: Readonly<Record<LoanDetail["source_type"], string>> = {
  proceeds: "Pencairan",
  opening: "Saldo Awal",
};

/**
 * Loan Detail (P13 Part 3f, second increment, Step 09 §10, §16: "Loan dashboard shows principal outstanding,
 * next due, interest/fee split and schedule"). Follows the same narrower "Standard Record Detail Pattern
 * subset" as Asset Detail (decision 174) -- Header / Summary / Schedule / Activity, here Header / Ringkasan /
 * Jadwal Cicilan / Riwayat Pembayaran -- rather than the full pattern with a separate placeholder section, since
 * `loan_detail`'s own versions and payments already ARE the loan's detail. Unlike Asset Detail, the active
 * schedule is a separate RPC (`loan_schedule`) rather than embedded in `loan_detail`, so the page fetches it
 * alongside. The principal/financial account ids on `loan_detail` are left unlinked (the "only link what has
 * somewhere to go" precedent, decision 172): there is no Chart of Accounts detail route yet to link to.
 */
export function LoanDetailScreen({
  detail,
  schedule,
  currency,
  entity,
  backHref,
}: {
  detail: LoanDetail;
  schedule: readonly LoanScheduleRow[];
  currency: string;
  entity: string | undefined;
  backHref: string;
}) {
  const statusBadge = loanStatusBadge(detail.status);
  const activeVersion =
    detail.versions.find((v) => v.status === "active") ??
    detail.versions[detail.versions.length - 1];
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar pinjaman</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">
            Pinjaman · {LOAN_DIRECTION_LABELS[detail.direction]}
          </p>
          <h1>{detail.number}</h1>
          <p className="record-detail-counterparty">{detail.counterparty}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Tujuan</dt>
            <dd>{detail.purpose}</dd>
          </div>
          <div>
            <dt>Tanggal Perjanjian</dt>
            <dd>{formatShortDate(detail.agreement_date)}</dd>
          </div>
          <div>
            <dt>Tanggal Efektif</dt>
            <dd>{detail.effective_date ? formatShortDate(detail.effective_date) : "—"}</dd>
          </div>
          {detail.closed_date ? (
            <div>
              <dt>Tanggal Lunas</dt>
              <dd>{formatShortDate(detail.closed_date)}</dd>
            </div>
          ) : null}
          <div>
            <dt>Pokok</dt>
            <dd>{formatMoney(detail.principal, currency)}</dd>
          </div>
          <div>
            <dt>Pokok Dicairkan</dt>
            <dd>{formatMoney(detail.funded_principal, currency)}</dd>
          </div>
          <div>
            <dt>Outstanding</dt>
            <dd>{formatMoney(detail.outstanding, currency)}</dd>
          </div>
          <div>
            <dt>Sumber</dt>
            <dd>{SOURCE_TYPE_LABELS[detail.source_type]}</dd>
          </div>
          {activeVersion ? (
            <>
              <div>
                <dt>Metode</dt>
                <dd>{LOAN_METHOD_LABELS[activeVersion.method as LoanMethod]}</dd>
              </div>
              <div>
                <dt>Bunga</dt>
                <dd>{activeVersion.rate}% / tahun</dd>
              </div>
            </>
          ) : null}
          {detail.asset_id ? (
            <div>
              <dt>Aset Terkait</dt>
              <dd>
                <Link href={`/assets/${detail.asset_id}${qs}`}>Lihat aset →</Link>
              </dd>
            </div>
          ) : null}
          {detail.relationship_basis ? (
            <div>
              <dt>Dasar Hubungan</dt>
              <dd>{detail.relationship_basis}</dd>
            </div>
          ) : null}
          {detail.cancel_reason ? (
            <div>
              <dt>Alasan Dibatalkan</dt>
              <dd>{detail.cancel_reason}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Jadwal Cicilan</h2>
        </div>
        {schedule.length === 0 ? (
          <p className="dashboard-empty">Belum ada jadwal cicilan.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">#</th>
                <th scope="col">Jatuh Tempo</th>
                <th scope="col" className="num">
                  Pokok
                </th>
                <th scope="col" className="num">
                  Bunga
                </th>
                <th scope="col" className="num">
                  Fee
                </th>
                <th scope="col" className="num">
                  Outstanding
                </th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {schedule.map((line) => {
                const lineBadge = loanScheduleStateBadge(line.state, line.overdue);
                return (
                  <tr key={line.seq}>
                    <td>{line.seq}</td>
                    <td>{formatShortDate(line.due_date)}</td>
                    <td className="num">{formatMoney(line.principal_due, currency)}</td>
                    <td className="num">{formatMoney(line.interest_due, currency)}</td>
                    <td className="num">{formatMoney(line.fee_due, currency)}</td>
                    <td className="num">{formatMoney(line.outstanding, currency)}</td>
                    <td>
                      <span className={`status-badge status-badge-${lineBadge.tone}`}>
                        {lineBadge.text}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>

      {detail.versions.length > 1 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Riwayat Jadwal</h2>
          </div>
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Versi</th>
                <th scope="col">Metode</th>
                <th scope="col" className="num">
                  Bunga
                </th>
                <th scope="col">Berlaku Sejak</th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {detail.versions.map((version) => {
                const versionBadge = loanVersionStatusBadge(version.status as LoanVersionStatus);
                return (
                  <tr key={version.id}>
                    <td>{version.version_no}</td>
                    <td>{LOAN_METHOD_LABELS[version.method as LoanMethod]}</td>
                    <td className="num">{version.rate}%</td>
                    <td>
                      {version.effective_from ? formatShortDate(version.effective_from) : "—"}
                    </td>
                    <td>
                      <span className={`status-badge status-badge-${versionBadge.tone}`}>
                        {versionBadge.text}
                      </span>
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Riwayat Pembayaran</h2>
        </div>
        {detail.payments.length === 0 ? (
          <p className="dashboard-empty">Belum ada pembayaran.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Nomor</th>
                <th scope="col">Tanggal</th>
                <th scope="col">Jenis</th>
                <th scope="col" className="num">
                  Pokok
                </th>
                <th scope="col" className="num">
                  Bunga
                </th>
                <th scope="col" className="num">
                  Fee
                </th>
                <th scope="col">Status</th>
                <th scope="col">Jurnal</th>
              </tr>
            </thead>
            <tbody>
              {detail.payments.map((payment) => {
                const paymentBadge = loanPaymentStatusBadge(payment.status);
                return (
                  <tr key={payment.id}>
                    <td>{payment.number}</td>
                    <td>{formatShortDate(payment.date)}</td>
                    <td>{LOAN_PAYMENT_KIND_LABELS[payment.kind as LoanPaymentKind]}</td>
                    <td className="num">{formatMoney(payment.principal, currency)}</td>
                    <td className="num">{formatMoney(payment.interest, currency)}</td>
                    <td className="num">{formatMoney(payment.fee, currency)}</td>
                    <td>
                      <span className={`status-badge status-badge-${paymentBadge.tone}`}>
                        {paymentBadge.text}
                      </span>
                    </td>
                    <td>
                      <Link href={`/accounting/journal/${payment.journal_id}${qs}`}>Lihat →</Link>
                      {payment.reversal_journal_id ? (
                        <>
                          {" · "}
                          <Link href={`/accounting/journal/${payment.reversal_journal_id}${qs}`}>
                            Pembalik →
                          </Link>
                        </>
                      ) : null}
                    </td>
                  </tr>
                );
              })}
            </tbody>
          </table>
        )}
      </section>
    </div>
  );
}
