import Link from "next/link";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { monthRange, summarizeIncome } from "@/domain/sales/income";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listIncomeCategories, listIncomeEntries } from "@/services/sales/income";
import { formatShortDate } from "@/features/sales/format";
import { ReportExportButtons } from "@/features/reports/ReportExportButtons";
import { todayInBusinessZone } from "@/lib/time";

/** Catat Pendapatan (decision 350): income that has no invoice -- the month's entries with their totals. Viewing
 * needs `invoices.view`; recording `invoices.issue` and `invoices.confirm_payment`; cancelling `invoices.void`. */
export default async function IncomeListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; month?: string; category?: string }>;
}) {
  const { entity, month: monthParam, category: categoryParam } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const today = todayInBusinessZone();
  const month = monthRange(monthParam ?? "") ? (monthParam as string) : today.slice(0, 7);
  const range = monthRange(month)!;
  const canRecord =
    can(access, entityId, "invoices.issue") && can(access, entityId, "invoices.confirm_payment");

  const [entries, categories, accounts, contacts] = await Promise.all([
    listIncomeEntries(entityId, range),
    listIncomeCategories(entityId).catch(() => []),
    getMoneyControl(entityId).catch(() => []),
    listContacts(entityId).catch(() => []),
  ]);
  const categoryNames = new Map(categories.map((c) => [c.id, c.name]));
  const accountNames = new Map(accounts.map((a) => [a.financial_account_id, a.name]));
  const contactNames = new Map(contacts.map((c) => [c.id, c.display_name]));
  const shown = categoryParam ? entries.filter((e) => e.category_id === categoryParam) : entries;
  const summary = summarizeIncome(shown);
  const currency = shown[0]?.currency ?? "IDR";
  const withEntity = (href: string) =>
    entity ? `${href}${href.includes("?") ? "&" : "?"}entity=${encodeURIComponent(entity)}` : href;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Catat Pendapatan</h1>
          <p className="list-screen-summary">
            Pendapatan yang tidak lewat invoice, misalnya penjualan tunai, jasa yang dibayar
            langsung, komisi, bunga, atau dividen. Cukup isi beberapa kolom; jurnalnya dibuat
            otomatis.
          </p>
        </div>
        {canRecord ? (
          <Link href={withEntity("/sales/income/new")} className="btn-primary">
            + Catat Pendapatan
          </Link>
        ) : null}
      </header>

      <section className="dashboard-section">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Bulan
            <input type="month" name="month" defaultValue={month} />
          </label>
          <label>
            Jenis
            <select name="category" defaultValue={categoryParam ?? ""}>
              <option value="">Semua jenis</option>
              {categories.map((c) => (
                <option key={c.id} value={c.id}>
                  {c.name}
                </option>
              ))}
            </select>
          </label>
          <button type="submit" className="btn-secondary">
            Tampilkan
          </button>
        </form>
      </section>

      <section className="dashboard-section" data-report-root>
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan Bulan Ini</h2>
        </div>
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Pendapatan</th>
              <th scope="col" className="num">
                Jumlah
              </th>
            </tr>
          </thead>
          <tbody>
            <tr>
              <td>Pendapatan usaha (ikut dasar PPh Final 0,5%)</td>
              <td className="num" data-label="Jumlah">
                {formatMoney(summary.turnover, currency)}
              </td>
            </tr>
            <tr>
              <td>Pendapatan di luar usaha (tidak ikut dasar PPh Final)</td>
              <td className="num" data-label="Jumlah">
                {formatMoney(summary.outside, currency)}
              </td>
            </tr>
            <tr>
              <th scope="row">Total ({summary.count} catatan)</th>
              <td className="num" data-label="Jumlah">
                <strong>{formatMoney(summary.total, currency)}</strong>
              </td>
            </tr>
          </tbody>
        </table>

        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Daftar Pendapatan</h2>
        </div>
        {shown.length === 0 ? (
          <p className="dashboard-empty">Belum ada pendapatan yang dicatat pada bulan ini.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Jenis</th>
                <th scope="col">Dari</th>
                <th scope="col">Rekening</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {shown.map((row) => (
                <tr key={row.id}>
                  <td data-label="Tanggal">
                    <Link href={withEntity(`/sales/income/${row.id}`)}>
                      {formatShortDate(row.entry_date)}
                    </Link>
                  </td>
                  <td data-label="Jenis">{categoryNames.get(row.category_id) ?? "Pendapatan"}</td>
                  <td data-label="Dari">
                    {row.contact_id ? (contactNames.get(row.contact_id) ?? "—") : "—"}
                  </td>
                  <td data-label="Rekening">{accountNames.get(row.financial_account_id) ?? "—"}</td>
                  <td className="num" data-label="Jumlah">
                    {formatMoney(row.amount, row.currency)}
                  </td>
                  <td data-label="Status">
                    {row.status === "reversed" ? "Dibatalkan" : "Tercatat"}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>
      <ReportExportButtons fileName={`pendapatan-${month}`} />
    </div>
  );
}
