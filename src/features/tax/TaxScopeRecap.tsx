import { Decimal } from "@/domain/money/decimal";
import { formatMoney } from "@/domain/money/format";
import { TAX_TYPE_LABELS } from "@/domain/tax/tax";
import { scopeTotals, type TaxScope } from "@/domain/tax/taxOverview";
import type { TaxScopeRow } from "@/schemas/tax";

/**
 * "Rekap Pajak": what was counted, paid and is still owed per tax type, for ONE month, ONE year or everything since
 * the start (decision 409). View only: the filter is a plain GET form (no script), so a filtered view can be linked.
 * Counted and paid are by tax period (the month the tax belongs to).
 */
export function TaxScopeRecap({
  scope,
  rows,
  currency,
  entity,
  currentMonth,
}: {
  scope: TaxScope;
  rows: TaxScopeRow[];
  currency: string;
  entity: string | undefined;
  /** "YYYY-MM" of today, the latest month that can be picked. */
  currentMonth: string;
}) {
  const href = (params: Record<string, string>) => {
    const query = new URLSearchParams(params);
    if (entity) query.set("entity", entity);
    return `/tax?${query.toString()}`;
  };
  const currentYear = Number(currentMonth.slice(0, 4));
  const years = Array.from({ length: 6 }, (_, i) => currentYear - i);
  const visible = rows.filter(
    (row) =>
      !Decimal.parse(row.accrued).isZero() ||
      !Decimal.parse(row.paid).isZero() ||
      !Decimal.parse(row.outstanding).isZero(),
  );
  const totals = scopeTotals(visible);
  const left = Number(totals.outstanding);

  return (
    <section className="dashboard-section tax-recap">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Rekap Pajak · {scope.label}</h2>
      </div>
      <p className="hint">
        Hanya untuk dilihat. Pajak dihitung menurut masa pajaknya (bulan pajak itu berlaku), bukan
        tanggal pencatatan.
      </p>

      <div className="tax-recap-filter">
        <div className="tax-chips" role="group" aria-label="Rentang waktu">
          <a
            className="tax-chip"
            data-active={scope.kind === "month" || undefined}
            href={href({ scope: "month", month: scope.month ?? currentMonth })}
          >
            <strong>Bulan</strong>
          </a>
          <a
            className="tax-chip"
            data-active={scope.kind === "year" || undefined}
            href={href({ scope: "year", year: String(scope.year) })}
          >
            <strong>Tahun</strong>
          </a>
          <a
            className="tax-chip"
            data-active={scope.kind === "all" || undefined}
            href={href({ scope: "all" })}
          >
            <strong>Seluruhnya</strong>
          </a>
        </div>
        {scope.kind === "month" ? (
          <form method="get" action="/tax" className="tax-recap-form">
            {entity ? <input type="hidden" name="entity" value={entity} /> : null}
            <input type="hidden" name="scope" value="month" />
            <input
              type="month"
              name="month"
              defaultValue={scope.month ?? currentMonth}
              min="2000-01"
              max={currentMonth}
              aria-label="Pilih bulan"
            />
            <button type="submit" className="button-secondary">
              Terapkan
            </button>
          </form>
        ) : null}
        {scope.kind === "year" ? (
          <form method="get" action="/tax" className="tax-recap-form">
            {entity ? <input type="hidden" name="entity" value={entity} /> : null}
            <input type="hidden" name="scope" value="year" />
            <select name="year" defaultValue={String(scope.year)} aria-label="Pilih tahun">
              {years.map((year) => (
                <option key={year} value={year}>
                  {year}
                </option>
              ))}
            </select>
            <button type="submit" className="button-secondary">
              Terapkan
            </button>
          </form>
        ) : null}
      </div>

      <div className="tax-split">
        <div className="tax-split-item">
          <span>Pajak dihitung</span>
          <strong>{formatMoney(totals.accrued, currency)}</strong>
        </div>
        <div className="tax-split-item">
          <span>Sudah dibayar</span>
          <strong>{formatMoney(totals.paid, currency)}</strong>
        </div>
        <div className="tax-split-item">
          <span>{left < 0 ? "Lebih bayar" : "Belum dibayar"}</span>
          <strong>
            {formatMoney(
              left < 0 ? Decimal.parse(totals.outstanding).negate().toString() : totals.outstanding,
              currency,
            )}
          </strong>
        </div>
      </div>

      {visible.length === 0 ? (
        <p className="dashboard-empty">
          Tidak ada pajak tercatat untuk {scope.label.toLowerCase()}.
        </p>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Jenis pajak</th>
              <th scope="col" className="num">
                Dihitung
              </th>
              <th scope="col" className="num">
                Dibayar
              </th>
              <th scope="col" className="num">
                Sisa
              </th>
            </tr>
          </thead>
          <tbody>
            {visible.map((row) => (
              <tr key={row.tax_type}>
                <td>{TAX_TYPE_LABELS[row.tax_type] ?? row.tax_type}</td>
                <td className="num" data-label="Dihitung">
                  {formatMoney(row.accrued, currency)}
                </td>
                <td className="num" data-label="Dibayar">
                  {formatMoney(row.paid, currency)}
                </td>
                <td className="num" data-label="Sisa">
                  {formatMoney(row.outstanding, currency)}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}
