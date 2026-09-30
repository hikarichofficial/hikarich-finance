import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import { vendorPaymentRowStatus } from "@/domain/purchases/vendorPaymentsList";
import type { VendorPaymentRow } from "@/schemas/purchases";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Payments Made List (P13 unbuilt-screens backlog, Step 09 primary sitemap). No Create toolbar:
 * `record_vendor_payment` is invoked from the Bill Detail's own Payment action (Step 09 §12: "Payment
 * action displays exact source account and resulting outstanding balance"), never a standalone "new
 * payment" form here -- the same reasoning `PaymentsListScreen.tsx` already carries for its Sales
 * counterpart.
 */

function buildHref(entity: string | undefined, q: string): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `/purchases/payments?${qs}` : "/purchases/payments";
}

export function VendorPaymentsListScreen({
  rows,
  query,
  entity,
}: {
  rows: readonly VendorPaymentRow[];
  query: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Pembayaran ke Vendor</h1>
          <p className="list-screen-summary">{rows.length} pembayaran ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari nomor pembayaran, vendor atau referensi…"
            aria-label="Cari pembayaran vendor"
          />
          <button type="submit" className="btn-secondary">
            Cari
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>
            {query.trim()
              ? "Tidak ada pembayaran yang cocok dengan pencarian ini."
              : "Belum ada pembayaran vendor yang tercatat."}
          </p>
          {query.trim() ? (
            <Link href={buildHref(entity, "")} className="btn-secondary list-empty-action">
              Hapus Saringan
            </Link>
          ) : null}
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">No. Pembayaran</th>
              <th scope="col">Vendor</th>
              <th scope="col">Tanggal</th>
              <th scope="col" className="num">
                Jumlah
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = vendorPaymentRowStatus(row);
              const href = entity
                ? `/purchases/payments/${row.payment_id}?entity=${encodeURIComponent(entity)}`
                : `/purchases/payments/${row.payment_id}`;
              return (
                <tr key={row.payment_id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.payment_number}
                      eyebrow="Pembayaran Vendor"
                      title={row.payment_number}
                      badges={[{ tone: status.tone, text: status.text }]}
                      fields={[
                        { label: "Vendor", value: row.vendor_name },
                        { label: "Tanggal", value: formatShortDate(row.payment_date) },
                        { label: "Jumlah", value: formatMoney(row.amount, row.currency) },
                        { label: "Jumlah Bill", value: String(row.bill_count) },
                        ...(row.reference ? [{ label: "Referensi", value: row.reference }] : []),
                      ]}
                    />
                  </td>
                  <td data-label="Vendor">{row.vendor_name}</td>
                  <td data-label="Tanggal">{formatShortDate(row.payment_date)}</td>
                  <td className="num" data-label="Jumlah">
                    {formatMoney(row.amount, row.currency)}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
