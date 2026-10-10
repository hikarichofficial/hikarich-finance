import { PrintButton } from "@/features/sales/PrintButton";
import { BackLink } from "@/features/shell/BackLink";
import { annualReconciliationStatusBadge } from "@/domain/payroll/taxLiabilities";
import type { WithholdingCertificateRow } from "@/schemas/payroll";
import type { PayslipIssuer } from "./PayslipDocument";
import { WithholdingCertificateDocument } from "./WithholdingCertificateDocument";

/**
 * The page around the certificate: the sheet itself, plus the print button and the back link in `no-print`,
 * so what reaches the printer or the PDF is the sheet alone -- the same arrangement as the payslip (decision
 * 382 and the OWNER's note of 9 October 2026 that the revision and status chrome must not print).
 */
export function WithholdingCertificateScreen({
  row,
  year,
  currency,
  issuer,
  issuedOn,
  backHref,
}: {
  row: WithholdingCertificateRow;
  year: number;
  currency: string;
  issuer: PayslipIssuer;
  issuedOn: string;
  backHref: string;
}) {
  const badge = annualReconciliationStatusBadge(row.status);

  return (
    <main className="doc-page">
      <div className="doc-actions no-print">
        <BackLink href={backHref}>← Kembali ke Pajak & Kewajiban</BackLink>
        <span className="doc-actions-end">
          <span className={`status-badge status-badge-${badge.tone}`}>{badge.text}</span>
          <PrintButton label="Cetak / kirim sebagai PDF" />
        </span>
      </div>

      <WithholdingCertificateDocument
        row={row}
        year={year}
        currency={currency}
        issuer={issuer}
        issuedOn={issuedOn}
      />

      {row.tax_id === null ? (
        <p className="hint no-print">
          NPWP karyawan disembunyikan sampai Anda melakukan verifikasi ulang. Bukti potong sebaiknya
          diterbitkan dengan NPWP tercantum.
        </p>
      ) : null}
    </main>
  );
}
