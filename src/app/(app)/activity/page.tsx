import { can } from "@/domain/authz/access";
import { requireAccess } from "@/services/identity/access";
import { listInvoicePositions, listPayments } from "@/services/sales/sales";
import { listVendorPayments } from "@/services/purchases/purchases";
import { mergeRecentActivity } from "@/domain/dashboard/dashboard";
import { RecentActivity } from "@/features/dashboard/RecentActivity";

const ACTIVITY_LIMIT = 100;

/**
 * Recent Activity (Step 09 §3 Overview, §8; decision 246): the full version of the Dashboard's own feed --
 * the same meaningful events only (confirmed customer and vendor payments, issued invoices), never a raw
 * log, each source included only when the viewer may see it (`invoices.view` / `bills.view`), exactly as
 * the Dashboard decides. The raw technical trail lives in the Audit Log.
 */
export default async function ActivityPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;
  const canInvoices = can(access, entityId, "invoices.view");
  const canBills = can(access, entityId, "bills.view");

  const [payments, invoices, vendorPayments] = await Promise.all([
    canInvoices ? listPayments(entityId, { limit: ACTIVITY_LIMIT }) : [],
    canInvoices ? listInvoicePositions(entityId) : [],
    canBills ? listVendorPayments(entityId, { limit: ACTIVITY_LIMIT }) : [],
  ]);

  const items = mergeRecentActivity(
    { customerPayments: payments, vendorPayments, issuedInvoices: invoices },
    ACTIVITY_LIMIT,
  );

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Aktivitas Terbaru</h1>
          <p className="list-screen-summary">
            Kejadian penting terakhir: pembayaran terkonfirmasi dan invoice yang diterbitkan.
          </p>
        </div>
      </header>
      <RecentActivity items={items} showAllLink={false} />
    </div>
  );
}
