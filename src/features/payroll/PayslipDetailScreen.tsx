import { PrintButton } from "@/features/sales/PrintButton";
import { BackLink } from "@/features/shell/BackLink";
import { payslipStatusBadge } from "@/domain/payroll/payslipList";
import { formatMoney } from "@/domain/money/format";
import { PAYROLL_TAX_MODE_LABELS, TAX_METHOD_LABELS } from "@/domain/payroll/payroll";
import type { PayslipDetail } from "@/schemas/payroll";
import { PayslipDocument, type PayslipIssuer } from "./PayslipDocument";
import { formatShortDate } from "./format";

/**
 * Payslip Detail (Step 09 §17). The page is the printable sheet itself (`PayslipDocument`) plus, below it, the
 * few facts that belong to the company rather than to the employee -- which run issued it, what was actually
 * paid out, how the tax rate was arrived at. Those sit in `no-print`, so what comes out of the printer, or
 * goes to the employee as a PDF, is the sheet alone (OWNER, 9 October 2026).
 *
 * The payslip is an immutable snapshot (`payroll_payslip_get` returns it as issued, never recomputed), so
 * nothing on this screen can go stale. Without `payroll.tax_view` the snapshot's whole `tax` key is absent
 * (decision 180) and both the sheet and the staff section below simply have no tax in them.
 */
export function PayslipDetailScreen({
  detail,
  currency,
  issuer,
  backHref,
}: {
  detail: PayslipDetail;
  currency: string;
  issuer: PayslipIssuer;
  backHref: string;
}) {
  const statusBadge = payslipStatusBadge(detail.status);

  return (
    <main className="doc-page">
      <div className="doc-actions no-print">
        <BackLink href={backHref}>← Kembali ke Slip Gaji</BackLink>
        <span className="doc-actions-end">
          <span className={`status-badge status-badge-${statusBadge.tone}`}>
            {statusBadge.text}
          </span>
          <PrintButton label="Cetak / kirim sebagai PDF" />
        </span>
      </div>

      <PayslipDocument detail={detail} currency={currency} issuer={issuer} />

      <section className="dashboard-section no-print">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Catatan internal</h2>
        </div>
        <p className="hint">Bagian ini tidak ikut tercetak dan tidak terlihat oleh karyawan.</p>
        <dl className="record-summary-grid">
          <div>
            <dt>Proses Payroll</dt>
            <dd>
              {detail.run_number} (revisi {detail.revision})
            </dd>
          </div>
          <div>
            <dt>Diterbitkan</dt>
            <dd>{formatShortDate(detail.issued_at.slice(0, 10))}</dd>
          </div>
          <div>
            <dt>Gaji Bersih Terbayar</dt>
            <dd>{formatMoney(detail.net_paid, currency)}</dd>
          </div>
          {detail.tax?.mode ? (
            <div>
              <dt>Metode Tarif</dt>
              <dd>{PAYROLL_TAX_MODE_LABELS[detail.tax.mode]}</dd>
            </div>
          ) : null}
          {detail.tax?.method ? (
            <div>
              <dt>Metode Penanggungan</dt>
              <dd>{TAX_METHOD_LABELS[detail.tax.method]}</dd>
            </div>
          ) : null}
          {detail.voided_at ? (
            <div>
              <dt>Dibatalkan</dt>
              <dd>{formatShortDate(detail.voided_at.slice(0, 10))}</dd>
            </div>
          ) : null}
          {detail.void_reason ? (
            <div>
              <dt>Alasan Dibatalkan</dt>
              <dd>{detail.void_reason}</dd>
            </div>
          ) : null}
        </dl>
      </section>
    </main>
  );
}
