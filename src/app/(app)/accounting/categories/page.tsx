import { can } from "@/domain/authz/access";
import { requireAccess } from "@/services/identity/access";
import { listCategoriesForAdmin } from "@/services/accounting/categories";
import {
  CATEGORY_KIND_LABELS,
  CategoryCreateForm,
  CategoryRowForm,
} from "@/features/categories/CategoryForms";

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
  const rows = await listCategoriesForAdmin(membership.entity_id);

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Kategori</h1>
          <p className="list-screen-summary">
            {rows.length} kategori. Pemetaan pajak dipakai otomatis saat baris invoice/tagihan tidak
            diisi pajaknya.
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
              <th scope="col">Pemetaan Pajak</th>
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
                <td data-label="Pemetaan Pajak">
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
