import { formatMoney } from "@/domain/money/format";
import type { WithholdingCertificateRow } from "@/schemas/payroll";
import type { PayslipIssuer } from "./PayslipDocument";

/**
 * Bukti Potong Tahunan PPh 21 — form 1721-A1 (OWNER, 10 October 2026; decision 397).
 *
 * The payslip answers "how did this month's pay become the amount in my bank". This answers a different
 * question, once a year: what the employer declared and withheld for the whole year, so the employee can
 * file their own SPT Tahunan from it. It is the same sheet furniture as the payslip (`.slip`, `.doc-page`,
 * `.no-print`) so the two print alike and nothing new had to be styled.
 *
 * Every figure comes from `payroll_withholding_certificate`, which runs the year's posted lines through the
 * same `pph21_annual` the December payroll itself used -- the certificate cannot disagree with the last
 * payslip. Nothing is computed here.
 *
 * The NPWP is printed when the reader has stepped up recently; otherwise the RPC sends null and the sheet
 * says so rather than printing a blank, because a certificate issued without the identifier is not usable.
 */

const MONTH_NAMES = [
  "Januari",
  "Februari",
  "Maret",
  "April",
  "Mei",
  "Juni",
  "Juli",
  "Agustus",
  "September",
  "Oktober",
  "November",
  "Desember",
] as const;

function monthName(month: number): string {
  return MONTH_NAMES[Math.min(Math.max(month, 1), 12) - 1] as string;
}

function Row({
  label,
  value,
  currency,
  total,
  minus,
}: {
  label: string;
  value: string | null;
  currency: string;
  total?: boolean;
  minus?: boolean;
}) {
  return (
    <div className={total ? "slip-line slip-line-total" : "slip-line"}>
      <span>{label}</span>
      <span className="slip-num">
        {value === null ? "—" : `${minus ? "−" : ""}${formatMoney(value, currency)}`}
      </span>
    </div>
  );
}

export function WithholdingCertificateDocument({
  row,
  year,
  currency,
  issuer,
  issuedOn,
}: {
  row: WithholdingCertificateRow;
  year: number;
  currency: string;
  issuer: PayslipIssuer;
  /** The date on the signature block, in ISO form; the page decides it, not this view. */
  issuedOn: string;
}) {
  // The PTKP codes are the form's own wording (TK/0, K/2 and so on), so they print as they are; only the
  // placeholder the database uses for "not recorded yet" needs translating.
  const ptkpLabel =
    row.ptkp_status === null || row.ptkp_status === "unknown" ? "—" : row.ptkp_status;
  const period =
    row.first_month === 1 && row.last_month === 12
      ? `Januari – Desember ${year}`
      : `${monthName(row.first_month)} – ${monthName(row.last_month)} ${year}`;

  return (
    <article className="slip">
      <header className="slip-head">
        <div className="slip-issuer">
          {issuer.logo ? (
            // eslint-disable-next-line @next/next/no-img-element
            <img className="slip-logo" src={issuer.logo} alt="" />
          ) : null}
          <div>
            <p className="slip-issuer-name">{issuer.name}</p>
            {issuer.secondName ? <p className="slip-issuer-brand">{issuer.secondName}</p> : null}
            {issuer.addressLines.map((line) => (
              <p key={line} className="slip-issuer-line">
                {line}
              </p>
            ))}
            {issuer.contact ? <p className="slip-issuer-line">{issuer.contact}</p> : null}
          </div>
        </div>
        <div className="slip-title">
          <p className="slip-kicker">Bukti Potong PPh 21</p>
          <p className="slip-period">Tahun Pajak {year}</p>
          <p className="slip-number">Formulir 1721-A1</p>
        </div>
      </header>

      <section className="slip-who">
        <div>
          <span>Nama Karyawan</span>
          <strong>{row.employee_name}</strong>
        </div>
        <div>
          <span>NPWP</span>
          <strong>{row.tax_id ?? "Perlu verifikasi ulang"}</strong>
        </div>
        <div>
          <span>Status PTKP</span>
          <strong>{ptkpLabel}</strong>
        </div>
        <div>
          <span>Jabatan</span>
          <strong>{row.position_title ?? "—"}</strong>
        </div>
        <div>
          <span>Masa Perolehan</span>
          <strong>{period}</strong>
        </div>
        <div>
          <span>Bulan Kerja</span>
          <strong>{row.months_worked}</strong>
        </div>
      </section>

      {row.status === "incomplete" ? (
        <p className="slip-note slip-note-void">
          Data pajak karyawan ini belum lengkap, jadi perhitungan tahunannya belum bisa dinyatakan.
          Lengkapi status PTKP dan NPWP pada data pajak karyawan lebih dulu.
        </p>
      ) : null}

      <section className="slip-tax">
        <h3>Perhitungan PPh 21 Setahun</h3>
        <Row label="Penghasilan bruto setahun" value={row.gross_income} currency={currency} />
        <Row
          label="Dikurangi biaya jabatan"
          value={row.occupational_cost}
          currency={currency}
          minus
        />
        <Row
          label="Dikurangi iuran pensiun / JHT yang dibayar karyawan"
          value={row.pension_deduction}
          currency={currency}
          minus
        />
        <Row label="Penghasilan neto setahun" value={row.net_income} currency={currency} total />
        <Row label="Dikurangi PTKP" value={row.ptkp} currency={currency} minus />
        <Row label="Penghasilan Kena Pajak (PKP)" value={row.pkp} currency={currency} total />
        <Row label="PPh 21 terutang setahun" value={row.annual_tax} currency={currency} total />
      </section>

      <section className="slip-tax">
        <h3>PPh 21 yang Dipotong</h3>
        <Row label="Dipotong selama tahun pajak" value={row.withheld} currency={currency} />
        {Number(row.refunded) > 0 ? (
          <Row
            label="Dikembalikan melalui gaji Desember"
            value={row.refunded}
            currency={currency}
            minus
          />
        ) : null}
        <Row
          label="PPh 21 yang ditanggung karyawan"
          value={row.borne_by_employee}
          currency={currency}
          total
        />
      </section>

      {row.status === "under_withheld" ? (
        <p className="slip-note">
          Masih ada kekurangan potong. Hubungi bagian keuangan sebelum menyampaikan SPT Tahunan
          Anda.
        </p>
      ) : null}

      <section className="slip-tax">
        <p className="slip-issuer-line">
          Bukti potong ini dipakai sebagai lampiran SPT Tahunan PPh Orang Pribadi Anda, yang
          disampaikan paling lambat 31 Maret {year + 1}.
        </p>
      </section>

      <footer className="slip-foot">
        <span>
          {issuer.name} — {issuedOn}
        </span>
        <span>Pemotong Pajak</span>
      </footer>
    </article>
  );
}
