import Link from "next/link";
import {
  CONTACT_FILTER_OPTIONS,
  CONTACT_KIND_LABELS,
  type ContactListFilter,
} from "@/domain/contacts/contactsList";
import type { ContactRow } from "@/schemas/contacts";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";

/**
 * Contacts List, shared by Customers (`/sales/customers`, Step 09 §11's own sitemap entry, "Sales:
 * Invoices; Payments Received; Refunds; Customers; Products & Services") and Vendors
 * (`/purchases/vendors`, Step 09 §12's own sitemap entry). One screen component serving both roles, the
 * `basePath`/`title`/`role` props fixed per page -- the exact same generalization precedent
 * `DocumentsListScreen` established for its Uploads/Evidence sub-routes (decision 198) and Other
 * Receivables/Payables established for financing (decision 176). Same header/toolbar/table/empty-state
 * structure every other List screen already uses. "Tambah Pelanggan"/"Tambah Vendor" is deferred to a
 * later increment (no `create_contact` UI yet) and routes through the catch-all placeholder for now
 * (decision 157's precedent).
 */

function buildHref(
  basePath: string,
  entity: string | undefined,
  filter: ContactListFilter | null,
  q: string,
): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (filter) params.set("status", filter);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `${basePath}?${qs}` : basePath;
}

export function ContactsListScreen({
  rows,
  activeFilter,
  query,
  entity,
  basePath,
  title,
  searchPlaceholder,
  emptyLabel,
  createLabel,
}: {
  rows: readonly ContactRow[];
  activeFilter: ContactListFilter | null;
  query: string;
  entity: string | undefined;
  basePath: string;
  title: string;
  searchPlaceholder: string;
  emptyLabel: string;
  /** When set, the person may add a contact: the header shows this button (decision 258). */
  createLabel?: string;
}) {
  const newHref = entity ? `${basePath}/new?entity=${encodeURIComponent(entity)}` : `${basePath}/new`;

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>{title}</h1>
          <p className="list-screen-summary">
            {rows.length} kontak{" "}
            {activeFilter ? `pada tampilan "${filterLabel(activeFilter)}"` : "ditampilkan"}.
          </p>
        </div>
        {createLabel ? (
          <Link href={newHref} className="btn-primary">
            {createLabel}
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <nav className="list-filter-tabs" aria-label="Saring status kontak">
          {CONTACT_FILTER_OPTIONS.map((option) => (
            <Link
              key={option.label}
              href={buildHref(basePath, entity, option.value, query)}
              className={
                option.value === activeFilter
                  ? "list-filter-tab list-filter-tab-active"
                  : "list-filter-tab"
              }
            >
              {option.label}
            </Link>
          ))}
        </nav>
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          {activeFilter ? <input type="hidden" name="status" value={activeFilter} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder={searchPlaceholder}
            aria-label={searchPlaceholder}
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>{query.trim() ? "Tidak ada kontak yang cocok dengan pencarian ini." : emptyLabel}</p>
          {query.trim() || activeFilter ? (
            <Link
              href={buildHref(basePath, entity, null, "")}
              className="btn-secondary list-empty-action"
            >
              Hapus Saringan
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nama</th>
              <th scope="col">Jenis</th>
              <th scope="col">Status</th>
              <th scope="col">Kontak</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const href = entity
                ? `${basePath}/${row.id}?entity=${encodeURIComponent(entity)}`
                : `${basePath}/${row.id}`;
              const statusTone = row.status === "active" ? "success" : "neutral";
              const statusText = row.status === "active" ? "Aktif" : "Tidak Aktif";
              const contactLine = [row.email, row.phone].filter(Boolean).join(" · ");
              return (
                <tr key={row.id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.display_name}
                      eyebrow={title}
                      title={row.display_name}
                      badges={[{ tone: statusTone, text: statusText }]}
                      fields={[
                        { label: "Jenis", value: CONTACT_KIND_LABELS[row.kind] },
                        { label: "Email", value: row.email ?? "—" },
                        { label: "Telepon", value: row.phone ?? "—" },
                      ]}
                    />
                  </td>
                  <td data-label="Jenis">{CONTACT_KIND_LABELS[row.kind]}</td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${statusTone}`}>{statusText}</span>
                  </td>
                  <td data-label="Kontak">{contactLine || "—"}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}

function filterLabel(filter: ContactListFilter): string {
  return CONTACT_FILTER_OPTIONS.find((option) => option.value === filter)?.label ?? filter;
}
