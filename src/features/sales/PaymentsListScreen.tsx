import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  paymentRowStatus,
  refundStatusDisplay,
  type PaymentListTone,
} from "@/domain/sales/paymentsList";
import type { PaymentListRow } from "@/schemas/sales";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Shared List screen behind both `/sales/payments` (Payments Received) and `/sales/refunds` (Refunds) --
 * the same `list_payments` rows, Refunds pre-filtered by the page to rows with refund activity (Step 09
 * primary sitemap lists them as two separate Sales nav items; `src/domain/sales/paymentsList.ts` has why
 * there is one shared component rather than a second list RPC). A Refunds row still links to
 * `/sales/payments/[id]` -- the payment is the only record that exists; there is no separate refund detail
 * route since no `list_refunds`-shaped RPC backs one yet. No Create toolbar: `record_payment` is invoked
 * from the (still unbuilt) invoice payment-confirmation flow, never a standalone "new payment" form here.
 */

function buildHref(basePath: string, entity: string | undefined, q: string): string {
  const params = new URLSearchParams();
  if (entity) params.set("entity", entity);
  if (q.trim()) params.set("q", q.trim());
  const qs = params.toString();
  return qs ? `${basePath}?${qs}` : basePath;
}

export function PaymentsListScreen({
  rows,
  query,
  entity,
  view,
  basePath,
  title,
  searchPlaceholder,
  emptyLabel,
}: {
  rows: readonly PaymentListRow[];
  query: string;
  entity: string | undefined;
  view: "received" | "refunds";
  basePath: string;
  title: string;
  searchPlaceholder: string;
  emptyLabel: string;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>{title}</h1>
          <p className="list-screen-summary">{rows.length} pembayaran ditampilkan.</p>
        </div>
      </header>

      {view === "refunds" ? (
        <p className="list-screen-hint">
          Halaman ini hanya daftar pembayaran yang sudah punya refund. Untuk membuat refund baru,
          buka <Link href={buildHref("/sales/payments", entity, "")}>Pembayaran Diterima</Link>,
          klik pembayarannya, lalu tekan <strong>Refund ke Pelanggan</strong>.
        </p>
      ) : null}

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
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
          <p>
            {query.trim() ? "Tidak ada pembayaran yang cocok dengan pencarian ini." : emptyLabel}
          </p>
          {query.trim() ? (
            <Link
              href={buildHref(basePath, entity, "")}
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
              <th scope="col">No. Pembayaran</th>
              <th scope="col">Pelanggan</th>
              <th scope="col">Tanggal</th>
              <th scope="col" className="num">
                Jumlah
              </th>
              <th scope="col">Status</th>
              {view === "refunds" ? <th scope="col">Refund</th> : null}
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const status = paymentRowStatus(row);
              const refund = refundStatusDisplay(row.refund_status);
              const href = entity
                ? `/sales/payments/${row.payment_id}?entity=${encodeURIComponent(entity)}`
                : `/sales/payments/${row.payment_id}`;
              const badges: { tone: PaymentListTone; text: string }[] = [
                { tone: status.tone, text: status.text },
              ];
              if (view === "refunds") badges.push({ tone: refund.tone, text: refund.text });
              return (
                <tr key={row.payment_id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.payment_number}
                      eyebrow="Pembayaran"
                      title={row.payment_number}
                      badges={badges}
                      fields={[
                        { label: "Pelanggan", value: row.customer_name },
                        { label: "Tanggal", value: formatShortDate(row.payment_date) },
                        { label: "Jumlah", value: formatMoney(row.amount, row.currency) },
                        ...(row.reference ? [{ label: "Referensi", value: row.reference }] : []),
                      ]}
                    />
                  </td>
                  <td data-label="Pelanggan">{row.customer_name}</td>
                  <td data-label="Tanggal">{formatShortDate(row.payment_date)}</td>
                  <td className="num" data-label="Jumlah">
                    {formatMoney(row.amount, row.currency)}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${status.tone}`}>
                      {status.text}
                    </span>
                  </td>
                  {view === "refunds" ? (
                    <td data-label="Refund">
                      <span className={`status-badge status-badge-${refund.tone}`}>
                        {refund.text}
                      </span>
                    </td>
                  ) : null}
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
