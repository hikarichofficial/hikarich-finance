import Link from "next/link";
import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import {
  computePersonalTax,
  type InstallmentResult,
  ptkpAmount,
  ptkpLabel,
  type PersonalTaxResult,
} from "@/domain/tax/personalTax";
import { monthNameId } from "@/domain/tax/tax";
import { BarChart, type ChartPoint } from "@/features/charts/InteractiveCharts";
import { PTKP_STATUSES, type PersonalTaxSummary } from "@/schemas/personalTax";
import { PtkpForm } from "./PtkpForm";

/** "0.005" -> "0,5%"; "0.35" -> "35%". */
function ratePercent(rate: string): string {
  const value = Math.round(Number(rate) * 10000) / 100;
  return `${String(value).replace(".", ",")}%`;
}

function Row({
  label,
  value,
  sign,
  strong,
  note,
}: {
  label: string;
  value: string;
  sign?: "minus" | "equals";
  strong?: boolean;
  note?: string;
}) {
  return (
    <li className="pp-row" data-strong={strong ? "true" : undefined} data-sign={sign}>
      <span className="pp-row-label">
        <i aria-hidden="true">{sign === "minus" ? "−" : sign === "equals" ? "=" : ""}</i>
        <span className="pp-row-text">
          {label}
          {note ? <small>{note}</small> : null}
        </span>
      </span>
      <span className="pp-row-value">{value}</span>
    </li>
  );
}

/**
 * Pajak Pribadi (decision 365): the yearly income-tax estimate of a Personal book, number first. One answer on
 * top (what is still to be paid), then the two calculations the owner asked for side by side -- PPh Final UMKM on
 * sales and the progressive tax on the net income of services -- each as a short ladder of steps that ends in a
 * figure. Everything is read from the books and from the owner's own PT; the only thing a person chooses is the
 * PTKP status. Nothing is recorded: it is an estimate until the year is settled.
 */
export function PersonalTaxScreen({
  summary,
  entity,
  currentYear,
  installment,
}: {
  summary: PersonalTaxSummary;
  entity: string | undefined;
  currentYear: number;
  /** The monthly PPh 25 instalment, from last year's tax; null for a year already settled. */
  installment: InstallmentResult | null;
}) {
  const result: PersonalTaxResult = computePersonalTax(summary);
  const cur = summary.currency;
  const money = (v: string) => formatMoney(v, cur);
  const withEntity = (path: string, params: Record<string, string> = {}) => {
    const query = new URLSearchParams(params);
    if (entity) query.set("entity", entity);
    const text = query.toString();
    return text ? `${path}?${text}` : path;
  };
  const settled = result.status === "settled";
  const { progressive: prog, final, ceiling } = result;
  const tariff = summary.rules.tariff;
  const finalRule = summary.rules.final;

  const ptkpAmounts: Record<string, string> = {};
  if (tariff) {
    for (const status of PTKP_STATUSES) {
      ptkpAmounts[status] = money(ptkpAmount(tariff.params, status).toString());
    }
  }

  const points: ChartPoint[] = summary.freelance.months.map((value, i) => ({
    key: `${summary.year}-${i + 1}`,
    short: monthNameId(i + 1).slice(0, 3),
    label: `Pendapatan jasa ${monthNameId(i + 1)} ${summary.year}`,
    value: Number(value),
    display: money(value),
  }));
  const hasServiceIncome = prog !== null && !Decimal.parse(prog.gross).isZero();
  const owed = Decimal.parse(result.totalToPay);
  const settledAmount =
    prog && final
      ? Decimal.parse(prog.credit)
          .add(Decimal.parse(prog.prepaid))
          .add(Decimal.parse(final.paid))
          .toString()
      : "0";
  const overpaid = prog !== null && Decimal.parse(prog.balance).isNegative();

  return (
    <div className="tax-page">
      <header className="tax-hero">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>Pajak Pribadi</h1>
          <p className="record-detail-dates">
            Tahun {summary.year} · {settled ? "sudah ditetapkan" : "perkiraan berjalan"} · dihitung
            otomatis dari catatan Anda
          </p>
          <div className="tax-chips">
            <span className="tax-chip">
              <span>Status PTKP</span>
              <strong>
                {summary.ptkp_status ? summary.ptkp_status : "Belum dipilih (dihitung TK/0)"}
              </strong>
            </span>
            <Link
              className="tax-chip"
              href={withEntity("/tax/personal", { year: String(summary.year - 1) })}
            >
              <strong>← {summary.year - 1}</strong>
            </Link>
            {summary.year < currentYear ? (
              <Link
                className="tax-chip"
                href={withEntity("/tax/personal", { year: String(summary.year + 1) })}
              >
                <strong>{summary.year + 1} →</strong>
              </Link>
            ) : null}
          </div>
        </div>
        <div className="tax-chips">
          <Link className="tax-chip" href={withEntity("/tax")}>
            <strong>Ringkasan Pajak</strong>
          </Link>
          <Link className="tax-chip" href={withEntity("/sales/income/new")}>
            <strong>Catat Pendapatan</strong>
          </Link>
        </div>
      </header>

      {!result.ready || !prog || !final || !ceiling ? (
        <section className="dashboard-section">
          <p className="dashboard-empty">{result.notReady}</p>
        </section>
      ) : (
        <>
          <section className="pp-answer" data-tone={owed.isPositive() ? "owe" : "clear"}>
            <div>
              <p className="pp-answer-label">
                {owed.isPositive()
                  ? "Perkiraan pajak yang masih harus dibayar"
                  : "Tidak ada pajak kurang bayar"}
              </p>
              <p className="pp-answer-value">{money(result.totalToPay)}</p>
              <p className="pp-answer-note">
                {overpaid
                  ? `Pajak yang sudah dipotong melebihi pajak progresif ${money(Decimal.parse(prog.balance).abs().toString())}; dikembalikan lewat SPT Tahunan.`
                  : "Pajak final dan pajak progresif tahun ini, setelah dikurangi pajak yang sudah dipotong dan yang sudah Anda setor."}
              </p>
            </div>
            <ul className="pp-equation" aria-label="Rumus">
              <li>
                <span>PPh Final UMKM</span>
                <strong>{money(final.tax)}</strong>
              </li>
              <li>
                <i aria-hidden="true">+</i>
                <span>PPh Progresif</span>
                <strong>{money(prog.tax)}</strong>
              </li>
              <li>
                <i aria-hidden="true">−</i>
                <span>Sudah dipotong & disetor</span>
                <strong>{money(settledAmount)}</strong>
              </li>
            </ul>
          </section>

          {summary.ptkp_status === null && hasServiceIncome ? (
            <p className="pp-callout" role="status">
              Status PTKP belum dipilih, jadi sementara dihitung sebagai TK/0 (Tidak kawin, tanpa
              tanggungan). Pilih status Anda di bawah agar perkiraan tepat.
            </p>
          ) : null}

          <div className="pp-cards">
            <section className="dashboard-section pp-card">
              <div className="dashboard-section-header">
                <h2 className="dashboard-section-title">
                  PPh Final UMKM · {ratePercent(final.rate)}
                </h2>
                <span className="delta-chip">Penjualan usaha</span>
              </div>
              <ul className="pp-ladder">
                <Row label="Penjualan usaha (omzet)" value={money(final.turnover)} />
                <Row
                  label="Bebas pajak untuk orang pribadi"
                  value={money(final.band)}
                  sign="minus"
                />
                <Row label="Dasar pengenaan" value={money(final.taxable)} sign="equals" />
                <Row
                  label={`Pajak final ${ratePercent(final.rate)}`}
                  value={money(final.tax)}
                  strong
                />
                <Row label="Sudah disetor (PPh Final)" value={money(final.paid)} sign="minus" />
                <Row
                  label="Kurang bayar"
                  value={money(Decimal.parse(final.balance).isNegative() ? "0" : final.balance)}
                  sign="equals"
                  strong
                />
              </ul>
              <div className="pp-meter" aria-hidden="true">
                <span
                  style={{
                    width: `${Math.min(100, Number(final.band) > 0 ? (Number(final.turnover) / Number(final.band)) * 100 : 0)}%`,
                  }}
                />
              </div>
              <p className="hint">
                {final.insideBand
                  ? `Masih bebas pajak. Sisa ${money(final.bandLeft)} sebelum mulai dikenai.`
                  : "Omzet sudah melewati batas bebas pajak; selisihnya dikenai tarif final."}
              </p>
              {Decimal.parse(summary.business.turnover).isZero() ? (
                <p className="hint">
                  Belum ada penjualan usaha. Catat pendapatan dengan kategori &ldquo;Pendapatan
                  Usaha (Penjualan)&rdquo; dan angka ini terisi sendiri.
                </p>
              ) : null}
            </section>

            <section className="dashboard-section pp-card">
              <div className="dashboard-section-header">
                <h2 className="dashboard-section-title">PPh Progresif · penghasilan neto</h2>
                <span className="delta-chip">Jasa &amp; pekerjaan bebas</span>
              </div>
              <ul className="pp-ladder">
                <Row
                  label="Pendapatan jasa (bruto)"
                  value={money(prog.gross)}
                  note="Dicatat di sini + honor dari PT Anda"
                />
                <Row label="Biaya usaha & jasa" value={money(prog.costs)} sign="minus" />
                <Row
                  label="Penghasilan neto"
                  value={money(prog.net)}
                  sign="equals"
                  note={prog.loss ? "Biaya melebihi pendapatan: tidak ada pajak" : undefined}
                />
                <Row
                  label={`PTKP ${prog.ptkpStatus}`}
                  value={money(prog.ptkp)}
                  sign="minus"
                  note={ptkpLabel(prog.ptkpStatus)}
                />
                <Row
                  label="Penghasilan kena pajak (PKP)"
                  value={money(prog.taxable)}
                  sign="equals"
                  note="Dibulatkan ke bawah ribuan"
                />
              </ul>

              {prog.layers.some((l) => !Decimal.parse(l.amount).isZero()) ? (
                <div className="pp-layers-wrap">
                  <table className="pp-layers">
                    <thead>
                      <tr>
                        <th scope="col">Lapisan</th>
                        <th scope="col" className="num">
                          Tarif
                        </th>
                        <th scope="col" className="num">
                          Bagian
                        </th>
                        <th scope="col" className="num">
                          Pajak
                        </th>
                      </tr>
                    </thead>
                    <tbody>
                      {prog.layers
                        .filter((l) => !Decimal.parse(l.amount).isZero())
                        .map((l) => (
                          <tr key={l.from}>
                            <th scope="row">
                              {l.to === null ? `di atas ${money(l.from)}` : `s/d ${money(l.to)}`}
                            </th>
                            <td className="num">{ratePercent(l.rate)}</td>
                            <td className="num">{money(l.amount)}</td>
                            <td className="num">{money(l.tax)}</td>
                          </tr>
                        ))}
                    </tbody>
                  </table>
                </div>
              ) : null}

              <ul className="pp-ladder">
                <Row label="Pajak progresif" value={money(prog.tax)} strong />
                <Row
                  label="Sudah dipotong (klien + PT Anda)"
                  value={money(prog.credit)}
                  sign="minus"
                />
                <Row
                  label="Sudah disetor (angsuran PPh 25)"
                  value={money(prog.prepaid)}
                  sign="minus"
                />
                <Row
                  label={overpaid ? "Lebih bayar" : "Kurang bayar"}
                  value={money(Decimal.parse(prog.balance).abs().toString())}
                  sign="equals"
                  strong
                />
              </ul>
              {hasServiceIncome ? (
                <p className="hint">
                  Rata-rata {String(prog.effectiveRate).replace(".", ",")}% dari pendapatan jasa.
                </p>
              ) : (
                <p className="hint">
                  Belum ada pendapatan jasa. Catat pendapatan dengan kategori &ldquo;Pendapatan Jasa
                  &amp; Pekerjaan Bebas&rdquo;, atau terima honor dari PT Anda: angka ini terisi
                  sendiri.
                </p>
              )}
            </section>
          </div>

          <div className="tax-grid">
            <div className="dashboard-column">
              <section className="dashboard-section">
                <div className="dashboard-section-header">
                  <h2 className="dashboard-section-title">
                    Pendapatan jasa per bulan · {summary.year}
                  </h2>
                  <span className="delta-chip">Total {money(prog.gross)}</span>
                </div>
                <BarChart
                  points={points}
                  tone="accent"
                  ariaLabel={`Pendapatan jasa per bulan ${summary.year}`}
                />
              </section>

              <section className="dashboard-section">
                <div className="dashboard-section-header">
                  <h2 className="dashboard-section-title">Status PTKP</h2>
                </div>
                {tariff ? (
                  <PtkpForm
                    entity={entity}
                    year={summary.year}
                    current={summary.ptkp_status}
                    amounts={ptkpAmounts}
                  />
                ) : null}
                <p className="hint">
                  PTKP mengurangi penghasilan neto sebelum dikenai tarif progresif. Cukup dipilih
                  sekali per tahun.
                </p>
              </section>
            </div>

            <div className="dashboard-column">
              {installment ? (
                <section className="dashboard-section">
                  <div className="dashboard-section-header">
                    <h2 className="dashboard-section-title">Angsuran PPh 25 bulanan</h2>
                    <span className="delta-chip">
                      {installment.kind === "amount" ? "Perkiraan" : "Nihil"}
                    </span>
                  </div>
                  <div className="tax-split">
                    <div className="tax-split-item">
                      <span>Per bulan</span>
                      <strong>{money(installment.monthly)}</strong>
                    </div>
                    <div className="tax-split-item">
                      <span>Disetor tahun ini</span>
                      <strong>{money(installment.paid)}</strong>
                    </div>
                    <div className="tax-split-item">
                      <span>Jatuh tempo</span>
                      <strong>Tgl {installment.dueDay} bulan berikutnya</strong>
                    </div>
                  </div>
                  <p className="hint">
                    {installment.kind === "amount"
                      ? `Pajak progresif tahun lalu dikurangi pajak yang dipotong (${money(installment.basis)}), dibagi 12. Setor lewat e-Billing lalu catat di Pembelian > Biaya dengan kategori "Setoran PPh 25 (Angsuran)"; angka di sini dan kurang bayar ikut menyesuaikan.`
                      : installment.reason}
                  </p>
                </section>
              ) : null}

              <section className="dashboard-section">
                <div className="dashboard-section-header">
                  <h2 className="dashboard-section-title">Dari PT Anda (otomatis)</h2>
                </div>
                {summary.linked_pt.length === 0 ? (
                  <p className="dashboard-empty">
                    Tidak ada honor dari PT Anda tahun ini. Bila ada, pembayaran PT ke Anda
                    (dikenali dari NPWP atau nama Anda di kontak PT) terbaca sendiri beserta pajak
                    yang dipotong, tanpa input apa pun di sini.
                  </p>
                ) : (
                  <ul className="pp-linked">
                    {summary.linked_pt.map((row) => (
                      <li key={`${row.entity_id}-${row.contact_id}`}>
                        <div>
                          <p className="pp-linked-title">{row.entity_name}</p>
                          <p className="pp-linked-sub">
                            {row.documents} dokumen · atas nama {row.contact_name}
                          </p>
                        </div>
                        <div className="pp-linked-amount">
                          <strong>{money(row.gross)}</strong>
                          <span>dipotong {money(row.withheld)}</span>
                        </div>
                      </li>
                    ))}
                  </ul>
                )}
              </section>

              <section className="dashboard-section">
                <div className="dashboard-section-header">
                  <h2 className="dashboard-section-title">Omzet gabungan {summary.year}</h2>
                  <span className="delta-chip" data-tone={ceiling.over ? "bad" : undefined}>
                    {Math.round(Number(ceiling.share) * 100)}%
                  </span>
                </div>
                <div
                  className="pp-meter"
                  data-tone={ceiling.over ? "bad" : undefined}
                  aria-hidden="true"
                >
                  <span style={{ width: `${Number(ceiling.share) * 100}%` }} />
                </div>
                <ul className="pp-parts">
                  {ceiling.parts.map((part) => (
                    <li key={part.name}>
                      <span>{part.name}</span>
                      <strong>{money(part.turnover)}</strong>
                    </li>
                  ))}
                  <li data-total="true">
                    <span>Total · batas {money(ceiling.ceiling)}</span>
                    <strong>{money(ceiling.total)}</strong>
                  </li>
                </ul>
                <p className="hint">
                  {ceiling.over
                    ? "Omzet gabungan melewati batas: PPh Final UMKM tidak berlaku lagi untuk sisa tahun ini."
                    : "Buku Pribadi dan PT Anda dijumlahkan otomatis untuk batas PPh Final UMKM."}
                </p>
              </section>
            </div>
          </div>

          <details className="tax-fold">
            <summary>Cara menghitung dan hal yang perlu Anda ketahui</summary>
            <ul className="pp-notes">
              <li>
                Penghasilan jasa dihitung dari <strong>penghasilan neto</strong>: pendapatan bruto
                dikurangi biaya yang ditandai &ldquo;Biaya usaha&rdquo; di Kategori. Pengeluaran
                tanpa tanda itu (belanja pribadi) tidak mengurangi pajak.
              </li>
              <li>
                Pajak yang dipotong klien diisi saat Catat Pendapatan. Pajak yang dipotong PT Anda
                dibaca otomatis dari dokumen PT.
              </li>
              <li>
                Tarif progresif:{" "}
                {tariff?.params.brackets
                  .map(
                    (b) =>
                      `${ratePercent(b.rate)}${b.up_to ? ` s/d ${money(b.up_to)}` : " di atasnya"}`,
                  )
                  .join(", ")}
                . Aturan: {tariff ? `${tariff.code} versi ${tariff.version}` : "-"}
                {finalRule ? `; ${finalRule.code} versi ${finalRule.version}` : ""}.
              </li>
              <li>
                Jatah bebas pajak Rp 500 juta hanya untuk penjualan usaha (PPh Final). Penghasilan
                jasa tidak memakainya dan dihitung penuh dengan tarif progresif.
              </li>
              <li>
                Pajak yang Anda setor sendiri (PPh Final dan angsuran PPh 25) dicatat sebagai biaya
                dengan kategori &ldquo;Setoran PPh Final UMKM&rdquo; atau &ldquo;Setoran PPh 25
                (Angsuran)&rdquo;, lalu otomatis mengurangi kekurangan bayar.
              </li>
              <li>
                Ini perkiraan. Angka tidak dicatat sebagai jurnal; tahun ditetapkan otomatis tiap 1
                Januari berikutnya. Penyusutan aset belum dihitung.
              </li>
              {!Decimal.parse(summary.business.withheld_not_credited).isZero() ? (
                <li>
                  Ada pajak dipotong {money(summary.business.withheld_not_credited)} dari penjualan
                  usaha. Itu tidak mengurangi pajak di halaman ini; tanyakan ke konsultan pajak.
                </li>
              ) : null}
            </ul>
          </details>
        </>
      )}
    </div>
  );
}
