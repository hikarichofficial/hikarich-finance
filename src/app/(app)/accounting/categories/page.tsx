import { can } from "@/domain/authz/access";
import { requireAccess } from "@/services/identity/access";
import {
  listCategoriesForAdmin,
  listCurrentCategoryAccounts,
} from "@/services/accounting/categories";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import {
  CATEGORY_KIND_LABELS,
  CategoryAccountForm,
  CategoryCreateForm,
  CategoryRowForm,
} from "@/features/categories/CategoryForms";
import { todayInBusinessZone } from "@/lib/time";

/** Categories (Step 03 §6, decision 262): every member may read them; adding one or changing its tax
 * mapping needs `categories.manage` (the RLS policy of the table). The tax mapping is the fallback a line
 * uses when it states no tax fact itself (Step 05 §10-§11). */
export default async function CategoriesPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const canManage = can(access, membership.entity_id, "categories.manage");
  const canMapAccount = canManage && can(access, membership.entity_id, "coa.manage");
  const today = todayInBusinessZone();
  const [rows, currentAccounts, ledgerAccounts] = await Promise.all([
    listCategoriesForAdmin(membership.entity_id),
    listCurrentCategoryAccounts(membership.entity_id, today),
    canMapAccount ? listLedgerAccounts(membership.entity_id).catch(() => []) : Promise.resolve([]),
  ]);
  const postable = ledgerAccounts.filter((a) => a.status === "active" && !a.is_group);
  const accountOptions = (classes: readonly string[]) =>
    postable
      .filter((a) => classes.includes(a.account_class))
      .map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }));
  const revenueAccounts = accountOptions(["revenue", "other_income"]);
  const expenseAccounts = accountOptions(["expense", "other_expense"]);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Kategori</h1>
          <p className="list-screen-summary">
            {rows.length} kategori. Kategori adalah jenis pendapatan atau beban pada baris
            invoice/tagihan (misalnya Jasa Konsultasi atau Sewa Kantor), bukan daftar pelanggan atau
            vendor. Pelanggan ada di menu Pelanggan di bagian Penjualan.
          </p>
        </div>
      </header>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Belum ada kategori.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis</th>
              <th scope="col">Perlakuan Pajak</th>
              <th scope="col">Akun & Berlaku Sejak</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={row.id}>
                <td>
                  {row.name}
                  {row.is_active ? "" : " (tidak aktif)"}
                </td>
                <td data-label="Jenis">{CATEGORY_KIND_LABELS[row.kind] ?? row.kind}</td>
                <td data-label="Perlakuan Pajak">
                  {canManage ? (
                    <CategoryRowForm
                      entity={entity}
                      id={row.id}
                      taxKey={row.tax_category_key}
                      isActive={row.is_active}
                    />
                  ) : (
                    (row.tax_category_key ?? "—")
                  )}
                </td>
                <td data-label="Akun">
                  {canMapAccount && (row.kind === "revenue" || row.kind === "expense") ? (
                    <CategoryAccountForm
                      entity={entity}
                      categoryId={row.id}
                      accounts={row.kind === "revenue" ? revenueAccounts : expenseAccounts}
                      currentAccountId={currentAccounts.get(row.id) ?? null}
                      today={today}
                    />
                  ) : currentAccounts.has(row.id) ? (
                    "Dipetakan"
                  ) : (
                    "Akun bawaan"
                  )}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}

      {canManage ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Tambah Kategori</h2>
          </div>
          <CategoryCreateForm entity={entity} />
        </section>
      ) : null}
    </div>
  );
}
