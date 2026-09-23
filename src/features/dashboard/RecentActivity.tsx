import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { RecentActivityItem, RecentActivityKind } from "@/domain/dashboard/dashboard";
import { formatShortDate } from "./format";

const KIND_HREF: Readonly<Record<RecentActivityKind, string>> = {
  customer_payment: "/sales/payments",
  vendor_payment: "/purchases/payments",
  invoice_issued: "/sales/invoices",
};

/** Recent Activity (Step 09 §8, Step 10 §10): a short, meaningful-events-only feed -- confirmed customer
 * and vendor payments and issued invoices -- never a raw log of every write. */
export function RecentActivity({ items }: { items: readonly RecentActivityItem[] }) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Aktivitas Terbaru</h2>
        <Link className="dashboard-section-link" href="/activity">
          Lihat semua
        </Link>
      </div>
      {items.length === 0 ? (
        <p className="dashboard-empty">Belum ada aktivitas untuk periode ini.</p>
      ) : (
        <ul className="dashboard-list">
          {items.map((item) => (
            <li key={`${item.kind}-${item.id}`} className="dashboard-list-item">
              <div>
                <p className="dashboard-list-item-title">
                  <Link href={KIND_HREF[item.kind]}>{item.title}</Link>
                </p>
                <p className="dashboard-list-item-detail">{item.counterparty}</p>
              </div>
              <div className="dashboard-list-item-end">
                <span className="dashboard-list-item-value">
                  {formatMoney(item.amount, item.currency)}
                </span>
                <span className="dashboard-list-item-date">{formatShortDate(item.date)}</span>
              </div>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
