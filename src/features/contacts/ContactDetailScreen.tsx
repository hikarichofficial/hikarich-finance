import Link from "next/link";
import { CONTACT_KIND_LABELS } from "@/domain/contacts/contactsList";
import type { ContactRow } from "@/schemas/contacts";
import { formatShortDate } from "./format";

/**
 * Contact Detail, shared by Customer Detail (`/sales/customers/[id]`) and Vendor Detail
 * (`/purchases/vendors/[id]`), the same `basePath`/`backLabel`-parameterized generalization
 * `ContactsListScreen` uses. Unlike a commercial document (Invoice/Bill Detail), a contact has no
 * issue/void/correct-style lifecycle of its own, so this keeps only the two Standard Record Detail
 * Pattern areas that actually apply -- Header and a Summary of its own recorded facts -- the same
 * narrower application `AccountDetailScreen` already established for a non-document record (decision
 * 169). Tax identifier is never fetched (see `schemas/contacts.ts`'s own doc comment) and so is not
 * shown here; revealing it on demand is a deferred increment, not a silent omission.
 */
export function ContactDetailScreen({
  contact,
  backHref,
  backLabel,
}: {
  contact: ContactRow;
  backHref: string;
  backLabel: string;
}) {
  const statusTone = contact.status === "active" ? "success" : "neutral";
  const statusText = contact.status === "active" ? "Aktif" : "Tidak Aktif";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← {backLabel}</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">{CONTACT_KIND_LABELS[contact.kind]}</p>
          <h1>{contact.display_name}</h1>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${statusTone}`}>{statusText}</span>
        </div>
      </header>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Ringkasan</h2>
        </div>
        <dl className="record-summary-grid">
          <div>
            <dt>Nama Legal</dt>
            <dd>{contact.legal_name ?? "—"}</dd>
          </div>
          <div>
            <dt>Email</dt>
            <dd>{contact.email ?? "—"}</dd>
          </div>
          <div>
            <dt>Telepon</dt>
            <dd>{contact.phone ?? "—"}</dd>
          </div>
          <div>
            <dt>Alamat</dt>
            <dd>{contact.address_line ?? "—"}</dd>
          </div>
          <div>
            <dt>Kota</dt>
            <dd>{contact.city ?? "—"}</dd>
          </div>
          <div>
            <dt>Kode Negara</dt>
            <dd>{contact.country_code ?? "—"}</dd>
          </div>
          {contact.notes ? (
            <div>
              <dt>Catatan</dt>
              <dd>{contact.notes}</dd>
            </div>
          ) : null}
          <div>
            <dt>Dibuat</dt>
            <dd>{formatShortDate(contact.created_at)}</dd>
          </div>
          <div>
            <dt>Terakhir Diperbarui</dt>
            <dd>{formatShortDate(contact.updated_at)}</dd>
          </div>
        </dl>
      </section>
    </div>
  );
}
