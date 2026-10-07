import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { monthLabel, yearOptions, yearTotals } from "@/domain/accounting/cashStatement";
import type { CashAccountOption, CashStatement } from "@/schemas/cashStatement";

/**
 * "Rekening Koran" main page (decisions 326-327): the twelve months of one year, with money in, money out and
 * closing balance per month. The year and the account are chosen at the top; each month name opens that
 * month's own statement page with its lines.
 */
export function CashStatementYearScreen({
  statement,
  accounts,
  accountId,
  year,
  currentYear,
  currency,
  entity,
}: {
  statement: CashStatement;
  accounts: readonly CashAccountOption[];
  accountId: string | null;
  year: number;
  currentYear: number;
  currency: string;
  entity: string | undefined;
}) {
  const money = (value: string | number) =>
    formatMoney(typeof value === "number" ? value.toFixed(2) : value, currency);
  const totals = yearTotals(statement.months);

  function monthHref(monthStart: string): string {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (accountId) params.set("account", accountId);
    const query = params.toString();
    return `/accounting/statement/${monthStart.slice(0, 7)}${query ? `?${query}` : ""}`;
  }

  function yearHref(target: number): string {
    const params = new URLSearchParams();
    if (entity) params.set("entity", entity);
    if (accountId) params.set("account", accountId);
    params.set("year", String(target));
    return `/accounting/statement?${params.toString()}`;
  }

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Rekening Koran</h1>
          <p className="list-screen-summary">
            Ringkasan uang masuk dan keluar kas &amp; bank per bulan, dari jurnal yang sudah
            diposting. Klik nama bulan untuk melihat rinciannya.
          </p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Rekening
            <select name="account" defaultValue={accountId ?? ""}>
              <option value="">Semua Kas &amp; Bank</option>
              {accounts.map((account) => (
                <option key={account.id} value={account.id}>
                  {account.name}
                </option>
              ))}
            </select>
          </label>
          <label>
            Tahun
            <select name="year" defaultValue={String(year)}>
              {yearOptions(year, currentYear).map((option) => (
                <option key={option} value={option}>
                  {option}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
        <nav className="stmt-pager" aria-label="Pindah tahun">
          <Link className="stmt-page" href={yearHref(year - 1)}>
            ‹ {year - 1}
          </Link>
          <Link className="stmt-page" href={yearHref(year + 1)}>
            {year + 1} ›
          </Link>
        </nav>
      </div>

      <section className="stmt-summary" aria-label={`Ringkasan tahun ${year}`}>
        <div className="stmt-card">
          <span className="stmt-card-label">Saldo Awal {year}</span>
          <strong>{money(totals.opening)}</strong>
        </div>
        <div className="stmt-card stmt-card-in">
          <span className="stmt-card-label">Uang Masuk</span>
          <strong>{money(totals.totalIn)}</strong>
        </div>
        <div className="stmt-card stmt-card-out">
          <span className="stmt-card-label">Uang Keluar</span>
          <strong>{money(totals.totalOut)}</strong>
        </div>
        <div className="stmt-card">
          <span className="stmt-card-label">Saldo Akhir {year}</span>
          <strong>{money(totals.closing)}</strong>
        </div>
      </section>

      <table className="record-table record-table-stacked">
        <thead>
          <tr>
            <th scope="col">Bulan</th>
            <th scope="col" className="num">
              Uang Masuk
            </th>
            <th scope="col" className="num">
              Uang Keluar
            </th>
            <th scope="col" className="num">
              Saldo Akhir
            </th>
          </tr>
        </thead>
        <tbody>
          {statement.months.map((month) => (
            <tr key={month.month}>
              <td data-label="Bulan">
                <Link href={monthHref(month.month)}>{monthLabel(month.month)}</Link>
              </td>
              <td data-label="Uang Masuk" className="num stmt-in">
                {money(month.masuk)}
              </td>
              <td data-label="Uang Keluar" className="num stmt-out">
                {money(month.keluar)}
              </td>
              <td data-label="Saldo Akhir" className="num">
                {money(month.saldo_akhir)}
              </td>
            </tr>
          ))}
        </tbody>
      </table>
    </div>
  );
}
