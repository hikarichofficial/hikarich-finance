import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import {
  BPJS_COMPONENT_LABELS,
  payrollPeriodName,
  type BpjsComponent,
} from "@/domain/payroll/payroll";
import type { PayslipDetail } from "@/schemas/payroll";
import { formatShortDate } from "./format";

/**
 * The payslip as the employee reads it (OWNER, 9 October 2026): a single sheet, print-clean, that an employer
 * can hand over or email. It replaces the stack of generic tables the screen used to be, and it is laid out
 * around the one question a payslip has to answer -- how the month's pay became the amount in the bank:
 *
 *   Penghasilan Bruto  -  Potongan  =  Gaji Dibawa Pulang
 *
 * The potongan column is split in two, because since decision 381 the two halves do different things: a
 * potongan that is really less income (an unpaid absence) lowers the PPh 21 base, while one that is the
 * employee repaying their own debt (a loan instalment, a kasbon) only lowers what is handed over. Printing
 * them apart is what makes the tax base on the sheet add up by eye, which is what the OWNER asked for.
 *
 * Nothing here is recomputed: every figure is read from the issued snapshot (`payroll_payslip_get`). The two
 * sums this view does do itself -- the gross and the deduction totals -- are checked against the snapshot's
 * own `gross_pay`/`net_pay` and, if they ever disagree, the sheet says so instead of quietly printing a
 * number that is not the one that was paid.
 *
 * Without `payroll.tax_view` the snapshot arrives with its whole `tax` key absent (decision 180). The sheet
 * then prints no tax figure at all -- not even a derived one -- and says in one line that take-home pay is
 * already after tax, so a viewer who may not see tax cannot read it off the page.
 */

export interface PayslipIssuer {
  name: string;
  addressLines: readonly string[];
  contact: string | null;
  logo: string | null;
}

interface Line {
  key: string;
  label: string;
  amount: string;
  /** A line the reader should not mistake for money leaving their pay (employer-paid BPJS). */
  muted?: boolean;
}

function sum(amounts: readonly string[]): Decimal {
  return amounts.reduce((total, amount) => total.add(Decimal.parse(amount)), Decimal.zero(4));
}

function bpjsLines(share: Readonly<Record<string, string>>): Line[] {
  return (Object.keys(BPJS_COMPONENT_LABELS) as BpjsComponent[])
    .map((component) => ({ component, key: component.replace(/^bpjs_/, "") }))
    .filter(({ key }) => share[key] !== undefined && share[key] !== "0")
    .map(({ component, key }) => ({
      key: component,
      label: BPJS_COMPONENT_LABELS[component],
      amount: share[key] as string,
    }));
}

function LineRows({ lines, currency }: { lines: readonly Line[]; currency: string }) {
  return (
    <>
      {lines.map((line) => (
        <div className="slip-line" key={line.key} data-muted={line.muted ? "true" : undefined}>
          <span>{line.label}</span>
          <span className="slip-num">{formatMoney(line.amount, currency)}</span>
        </div>
      ))}
    </>
  );
}

export function PayslipDocument({
  detail,
  currency,
  issuer,
}: {
  detail: PayslipDetail;
  currency: string;
  issuer: PayslipIssuer;
}) {
  const earnings: Line[] = [
    ...detail.components
      .filter((c) => c.kind === "earning")
      .map((c) => ({ key: `c-${c.code}`, label: c.label, amount: c.amount })),
    ...detail.adjustments
      .filter((a) => a.kind === "earning")
      .map((a, index) => ({ key: `ae-${index}`, label: a.label, amount: a.amount })),
  ];

  // Decision 381: the two kinds of potongan are listed apart, because only the first lowers the PPh 21 base.
  const taxReducing: Line[] = [
    ...detail.components
      .filter((c) => c.kind === "deduction" && c.taxable)
      .map((c) => ({ key: `c-${c.code}`, label: c.label, amount: c.amount })),
    ...detail.adjustments
      .filter((a) => a.kind === "deduction" && a.taxable)
      .map((a, index) => ({ key: `ad-${index}`, label: a.label, amount: a.amount })),
  ];
  const takeHomeOnly: Line[] = [
    ...detail.components
      .filter((c) => c.kind === "deduction" && !c.taxable)
      .map((c) => ({ key: `c-${c.code}`, label: c.label, amount: c.amount })),
    ...detail.adjustments
      .filter((a) => a.kind === "deduction" && !a.taxable)
      .map((a, index) => ({ key: `an-${index}`, label: a.label, amount: a.amount })),
  ];
  const bpjsEmployee = bpjsLines(detail.bpjs_employee);
  const bpjsEmployer = bpjsLines(detail.bpjs_employer);

  const gross = sum(earnings.map((l) => l.amount));
  const bpjsEmployeeTotal = sum(bpjsEmployee.map((l) => l.amount));
  const withheld = detail.tax ? Decimal.parse(detail.tax.withheld_from_employee) : null;
  const deductionsTotal = sum([
    ...taxReducing.map((l) => l.amount),
    ...takeHomeOnly.map((l) => l.amount),
  ])
    .add(bpjsEmployeeTotal)
    .add(withheld ?? Decimal.zero(4));

  // The snapshot is the authority; these sums only present it. If they disagree, say so rather than print on.
  const netPay = Decimal.parse(detail.net_pay);
  const mismatch = detail.tax ? !gross.sub(deductionsTotal).eq(netPay) : false;

  const taxableEarnings = sum([
    ...detail.components.filter((c) => c.kind === "earning" && c.taxable).map((c) => c.amount),
    ...detail.adjustments.filter((a) => a.kind === "earning" && a.taxable).map((a) => a.amount),
  ]);
  const taxableReductions = sum(taxReducing.map((l) => l.amount));
  const taxRuleAdjustment = detail.tax
    ? Decimal.parse(detail.tax.base).sub(taxableEarnings.sub(taxableReductions))
    : null;

  return (
    <article className="slip" data-void={detail.status === "voided" ? "true" : undefined}>
      <header className="slip-head">
        <div className="slip-issuer">
          {issuer.logo ? (
            // The logo is an Entity setting stored as a data URL, not a file in /public: next/image cannot size it.
            // eslint-disable-next-line @next/next/no-img-element
            <img className="slip-logo" src={issuer.logo} alt="" />
          ) : null}
          <div>
            <p className="slip-issuer-name">{issuer.name}</p>
            {issuer.addressLines.map((line) => (
              <p key={line} className="slip-issuer-line">
                {line}
              </p>
            ))}
            {issuer.contact ? <p className="slip-issuer-line">{issuer.contact}</p> : null}
          </div>
        </div>
        <div className="slip-title">
          <p className="slip-kicker">Slip Gaji</p>
          <p className="slip-period">{payrollPeriodName(`${detail.period}-01`)}</p>
          <p className="slip-number">{detail.payslip_number}</p>
        </div>
      </header>

      <section className="slip-who">
        <div>
          <span>Nama Karyawan</span>
          <strong>{detail.employee.name}</strong>
        </div>
        <div>
          <span>Kode Karyawan</span>
          <strong>{detail.employee.code}</strong>
        </div>
        <div>
          <span>Tanggal Bayar</span>
          <strong>{formatShortDate(detail.pay_date)}</strong>
        </div>
      </section>

      {detail.status === "voided" ? (
        <p className="slip-note slip-note-void">
          Slip ini dibatalkan pada {formatShortDate((detail.voided_at ?? "").slice(0, 10))}
          {detail.void_reason ? ` — ${detail.void_reason}` : ""}. Slip ini tidak berlaku.
        </p>
      ) : null}

      <div className="slip-columns">
        <section className="slip-col">
          <h3>Penghasilan</h3>
          <LineRows lines={earnings} currency={currency} />
          <div className="slip-line slip-line-total">
            <span>Penghasilan Bruto</span>
            <span className="slip-num">{formatMoney(gross.toString(), currency)}</span>
          </div>
        </section>

        <section className="slip-col">
          <h3>Potongan</h3>

          {taxReducing.length > 0 ? (
            <>
              <p className="slip-group">Mengurangi penghasilan, jadi mengurangi dasar PPh 21</p>
              <LineRows lines={taxReducing} currency={currency} />
            </>
          ) : null}

          {bpjsEmployee.length > 0 || withheld !== null ? (
            <>
              <p className="slip-group">Iuran dan pajak karyawan</p>
              <LineRows lines={bpjsEmployee} currency={currency} />
              {withheld !== null ? (
                <div className="slip-line">
                  <span>PPh 21</span>
                  <span className="slip-num">{formatMoney(withheld.toString(), currency)}</span>
                </div>
              ) : null}
            </>
          ) : null}

          {takeHomeOnly.length > 0 ? (
            <>
              <p className="slip-group">
                Tidak mengurangi dasar PPh 21 — penghasilan tetap diterima penuh, lalu dipakai
                membayar kewajiban ke perusahaan
              </p>
              <LineRows lines={takeHomeOnly} currency={currency} />
            </>
          ) : null}

          <div className="slip-line slip-line-total">
            <span>Total Potongan</span>
            <span className="slip-num">
              {detail.tax ? formatMoney(deductionsTotal.toString(), currency) : "—"}
            </span>
          </div>
        </section>
      </div>

      <section className="slip-takehome">
        <div>
          <p className="slip-kicker">Gaji Dibawa Pulang</p>
          <p className="slip-takehome-sub">Penghasilan bruto dikurangi seluruh potongan di atas</p>
        </div>
        <p className="slip-takehome-amount">{formatMoney(detail.net_pay, currency)}</p>
      </section>

      {!detail.tax ? (
        <p className="slip-note">
          Gaji dibawa pulang di atas sudah dikurangi pajak penghasilan. Rincian pajaknya tidak
          ditampilkan pada tampilan ini.
        </p>
      ) : null}

      {mismatch ? (
        <p className="slip-note slip-note-void">
          Angka pada slip ini tidak menjumlah seperti seharusnya. Jangan dipakai; laporkan ke
          pengelola sistem.
        </p>
      ) : null}

      {detail.tax ? (
        <section className="slip-tax">
          <h3>Dasar Perhitungan PPh 21</h3>
          <div className="slip-line">
            <span>Penghasilan yang kena pajak</span>
            <span className="slip-num">{formatMoney(taxableEarnings.toString(), currency)}</span>
          </div>
          {taxableReductions.isZero() ? null : (
            <div className="slip-line">
              <span>Dikurangi potongan yang mengurangi penghasilan</span>
              <span className="slip-num">
                −{formatMoney(taxableReductions.toString(), currency)}
              </span>
            </div>
          )}
          {taxRuleAdjustment && !taxRuleAdjustment.isZero() ? (
            <div className="slip-line">
              <span>
                Ditambah iuran BPJS yang dibayar perusahaan dan menjadi objek pajak menurut aturan
              </span>
              <span className="slip-num">
                {taxRuleAdjustment.isNegative() ? "" : "+"}
                {formatMoney(taxRuleAdjustment.toString(), currency)}
              </span>
            </div>
          ) : null}
          <div className="slip-line slip-line-total">
            <span>Dasar Pengenaan Pajak</span>
            <span className="slip-num">{formatMoney(detail.tax.base, currency)}</span>
          </div>
          <div className="slip-line">
            <span>PPh 21 bulan ini</span>
            <span className="slip-num">{formatMoney(detail.tax.pph21, currency)}</span>
          </div>
          {Decimal.parse(detail.tax.allowance).isZero() ? null : (
            <div className="slip-line">
              <span>Tunjangan pajak dari perusahaan</span>
              <span className="slip-num">{formatMoney(detail.tax.allowance, currency)}</span>
            </div>
          )}
        </section>
      ) : null}

      {bpjsEmployer.length > 0 ? (
        <section className="slip-employer">
          <h3>Dibayar Perusahaan untuk Anda</h3>
          <p className="slip-group">
            Tidak dipotong dari gaji; dicantumkan supaya terlihat nilai penuh yang diterima.
          </p>
          <LineRows lines={bpjsEmployer} currency={currency} />
        </section>
      ) : null}

      <footer className="slip-foot">
        <span>
          Diterbitkan {formatShortDate(detail.issued_at.slice(0, 10))} · {detail.run_number}
          {detail.revision > 1 ? ` revisi ${detail.revision}` : ""}
        </span>
        <span>Dokumen ini dibuat otomatis dan sah tanpa tanda tangan.</span>
      </footer>
    </article>
  );
}
