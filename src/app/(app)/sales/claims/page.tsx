import Link from "next/link";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listPendingPaymentClaims } from "@/services/sales/sales";
import { formatMoney } from "@/domain/money/format";
import { formatShortDate } from "@/features/sales/format";
import { PaymentClaimForms } from "@/features/sales/PaymentClaimForms";

/** Payment Confirmation queue (Step 09 §11, Step 07 §4, decision 259): the pending "Saya Sudah Bayar"
 * claims of the Entity. Viewing needs `invoices.view`; confirming or rejecting needs
 * `invoices.confirm_payment`, the permission the RPCs check. */
export default async function PaymentClaimsPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const canConfirm = can(access, membership.entity_id, "invoices.confirm_payment");
  const [claims, accounts] = await Promise.all([
    listPendingPaymentClaims(membership.entity_id),
    canConfirm ? getMoneyControl(membership.entity_id).catch(() => []) : Promise.resolve([]),
  ]);
  const accountOptions = accounts
    .filter((a) => a.is_active)
    .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }));
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Klaim Pembayaran</h1>
          <p className="list-screen-summary">
            {claims.length} klaim menunggu konfirmasi. Klaim belum dihitung sebagai pembayaran sampai
            dikonfirmasi.
          </p>
        </div>
      </header>

      {claims.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada klaim yang menunggu.</p>
        </div>
      ) : (
        claims.map((claim) => (
          <section key={claim.id} className="dashboard-section">
            <div className="dashboard-section-header">
              <h2 className="dashboard-section-title">
                {formatMoney(claim.amount, claim.currency)} ·{" "}
                <Link href={`/sales/invoices/${claim.invoice_id}${qs}`}>
                  {claim.invoice_number ?? "Invoice"}
                </Link>
              </h2>
            </div>
            <dl className="record-summary-grid">
              <div>
                <dt>Tanggal Bayar (menurut klaim)</dt>
                <dd>{formatShortDate(claim.payment_date)}</dd>
              </div>
              <div>
                <dt>Nama Pembayar</dt>
                <dd>{claim.payer_name ?? "—"}</dd>
              </div>
              <div>
                <dt>Referensi</dt>
                <dd>{claim.payer_reference ?? "—"}</dd>
              </div>
              <div>
                <dt>Sumber</dt>
                <dd>{claim.source === "public" ? "Link publik (pelanggan)" : "Dicatat staf"}</dd>
              </div>
              {claim.note ? (
                <div>
                  <dt>Catatan</dt>
                  <dd>{claim.note}</dd>
                </div>
              ) : null}
            </dl>
            {canConfirm ? (
              <PaymentClaimForms
                submissionId={claim.id}
                accounts={accountOptions}
                amount={claim.amount}
                paymentDate={claim.payment_date}
              />
            ) : null}
          </section>
        ))
      )}
    </div>
  );
}
