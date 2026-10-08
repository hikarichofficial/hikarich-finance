import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { Decimal } from "@/domain/money/decimal";
import { monthNameId } from "@/domain/tax/tax";
import type { NonFinalIncome } from "@/schemas/tax";
import { formatShortDate } from "./format";

/**
 * "Penghasilan di Luar PPh Final" (decision 352): the result since 1 January of income that is NOT in the
 * 0,5% final-tax base (interest, dividends, forex and other trading results, crypto, bonus and cashback, ...),
 * read from the journals on every visit, with an ESTIMATE of the yearly tax at 22%. Nothing is recorded: the
 * year is settled on 1 January of the next year and the annual return (SPT Tahunan) is due on 30 April.
 */
export function TaxNonFinalCard({
  data,
  currentYear,
  entity,
}: {
  data: NonFinalIncome;
  currentYear: number;
  entity: string | undefined;
}) {
  const settled = data.status === "settled";
  const yearHref = (year: number) =>
    `/tax?year=${year}${entity ? `&entity=${encodeURIComponent(entity)}` : ""}`;
  const monthsWithActivity = data.month_totals
    .map((total, index) => ({ total, month: index + 1 }))
    .filter(({ month }) => data.rows.some((row) => !Decimal.parse(row.months[month - 1]).isZero()));
  const rate = data.rate === null ? null : Math.round(Number(data.rate) * 100);

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Penghasilan di Luar PPh Final · {data.year}</h2>
        <span
          className={`status-badge ${settled ? "status-badge-success" : "status-badge-progress"}`}
        >
          {settled ? "Ditetapkan" : "Berjalan"}
        </span>
      </div>
      <p className="hint">
        Bunga, dividen, hasil trading forex, kripto, bonus dan penghasilan lain di luar usaha. Tidak
        ikut dasar PPh Final 0,5%. Dihitung dari pembukuan sejak 1 Januari {data.year}; hasil bersih
        sudah dikurangi rugi dan biaya trading.{" "}
        {settled
          ? `Hasil tahun ini ditetapkan pada ${formatShortDate(data.settles_on)}.`
          : `Hasil tahun ini ditetapkan otomatis pada ${formatShortDate(data.settles_on)}.`}{" "}
        SPT Tahunan tetap jatuh tempo {formatShortDate(data.annual_return_due)}.
      </p>

      {data.rows.length === 0 ? (
        <p className="dashboard-empty">
          Belum ada penghasilan di luar PPh Final pada tahun {data.year}.
        </p>
      ) : (
        <>
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Jenis penghasilan</th>
                <th scope="col" className="num">
                  Hasil bersih {data.year}
                </th>
              </tr>
            </thead>
            <tbody>
              {data.rows.map((row) => (
                <tr key={row.code}>
                  <td>
                    {row.name}
                    {row.counted ? "" : " (belum direalisasi, tidak dihitung)"}
                  </td>
                  <td className="num" data-label="Hasil bersih">
                    {formatMoney(row.total, data.currency)}
                  </td>
                </tr>
              ))}
              <tr>
                <th scope="row">Total hasil bersih</th>
                <td className="num" data-label="Total">
                  <strong>{formatMoney(data.total, data.currency)}</strong>
                </td>
              </tr>
            </tbody>
          </table>

          <details>
            <summary>Lihat per bulan</summary>
            <table className="record-table record-table-stacked">
              <thead>
                <tr>
                  <th scope="col">Bulan</th>
                  <th scope="col" className="num">
                    Hasil bersih
                  </th>
                </tr>
              </thead>
              <tbody>
                {monthsWithActivity.map(({ month, total }) => (
                  <tr key={month}>
                    <td>{monthNameId(month)}</td>
                    <td className="num" data-label="Hasil bersih">
                      {formatMoney(total, data.currency)}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </details>
        </>
      )}

      {rate !== null && data.estimated_tax !== null ? (
        <dl className="record-summary-grid">
          <div>
            <dt>
              Perkiraan pajak tahun {data.year} ({rate}%)
            </dt>
            <dd>{formatMoney(data.estimated_tax, data.currency)}</dd>
          </div>
        </dl>
      ) : (
        <p className="hint">
          Perkiraan pajak belum ditampilkan: jenis wajib pajak Entity belum diisi sebagai badan di
          Pengaturan Pajak.
        </p>
      )}
      <p className="hint">
        Ini perkiraan dengan asumsi tarif {rate ?? 22}% atas hasil bersih di atas, bukan angka
        final. Belum memperhitungkan fasilitas, kompensasi rugi, pajak yang sudah dipotong pihak
        lain (mis. bunga bank), maupun biaya usaha. Konfirmasikan dengan konsultan pajak sebelum
        SPT.
      </p>
      <p className="hint">
        {settled ? (
          <Link href={yearHref(currentYear)}>Lihat tahun berjalan →</Link>
        ) : (
          <Link href={yearHref(currentYear - 1)}>Lihat tahun lalu →</Link>
        )}
      </p>
    </section>
  );
}
