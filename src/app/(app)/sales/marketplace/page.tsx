import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listMarketplaceSettlements, listMarketplaceStores } from "@/services/sales/sales";
import { formatShortDate } from "@/features/sales/format";
import {
  MarketplaceSettlementForm,
  MarketplaceStoreForm,
  ReverseSettlementForm,
} from "@/features/sales/MarketplaceForms";
import { MARKETPLACE_PLATFORM_LABELS } from "@/features/sales/marketplaceLabels";
import { todayInBusinessZone } from "@/lib/time";

/** Marketplace (decision 260): the Entity's stores and their settlements (payouts). Viewing needs
 * `invoices.view`; adding a store `invoices.create`; recording a settlement `invoices.issue` and
 * `invoices.confirm_payment`; reversing one `invoices.void` -- the permissions the RPCs check. */
export default async function MarketplacePage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("invoices.view", { entityCode: entity });
  const entityId = membership.entity_id;
  const canAddStore = can(access, entityId, "invoices.create");
  const canRecord =
    can(access, entityId, "invoices.issue") && can(access, entityId, "invoices.confirm_payment");
  const canReverse = can(access, entityId, "invoices.void");
  const [stores, settlements, accounts] = await Promise.all([
    listMarketplaceStores(entityId),
    listMarketplaceSettlements(entityId),
    canAddStore || canRecord ? getMoneyControl(entityId).catch(() => []) : Promise.resolve([]),
  ]);
  const accountOptions = accounts
    .filter((a) => a.is_active)
    .map((a) => ({ id: a.financial_account_id, label: `${a.name} (${a.currency})` }));
  const storeLabel = new Map(
    stores.map((s) => [
      s.id,
      `${MARKETPLACE_PLATFORM_LABELS[s.platform] ?? s.platform} · ${s.name}`,
    ]),
  );
  const activeStores = stores.filter((s) => s.is_active);
  const today = todayInBusinessZone();

  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Marketplace</h1>
          <p className="list-screen-summary">
            {stores.length} toko · {settlements.length} pencairan terakhir. Penjualan marketplace
            dicatat per pencairan dana.
          </p>
        </div>
      </header>

      {canRecord && activeStores.length > 0 ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Catat Pencairan</h2>
          </div>
          <MarketplaceSettlementForm
            entity={entity}
            stores={activeStores.map((s) => ({
              id: s.id,
              label: storeLabel.get(s.id) ?? s.name,
              accountId: s.settlement_financial_account_id,
            }))}
            accounts={accountOptions}
            today={today}
          />
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Pencairan</h2>
        </div>
        {settlements.length === 0 ? (
          <p className="dashboard-empty">Belum ada pencairan yang dicatat.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Toko</th>
                <th scope="col">Tanggal Cair</th>
                <th scope="col" className="num">
                  Penjualan
                </th>
                <th scope="col" className="num">
                  Biaya
                </th>
                <th scope="col" className="num">
                  PPh 22
                </th>
                <th scope="col" className="num">
                  PPN
                </th>
                <th scope="col" className="num">
                  Dana Cair
                </th>
                <th scope="col">Status</th>
              </tr>
            </thead>
            <tbody>
              {settlements.map((row) => (
                <tr key={row.id}>
                  <td>{storeLabel.get(row.store_id) ?? "Toko"}</td>
                  <td data-label="Tanggal Cair">{formatShortDate(row.settlement_date)}</td>
                  <td className="num" data-label="Penjualan">
                    {formatMoney(row.gross_sales, row.currency)}
                  </td>
                  <td className="num" data-label="Biaya">
                    {formatMoney(row.fee_amount, row.currency)}
                  </td>
                  <td className="num" data-label="PPh 22">
                    {formatMoney(row.pph22_amount, row.currency)}
                  </td>
                  <td className="num" data-label="PPN">
                    {formatMoney(row.vat_amount, row.currency)}
                  </td>
                  <td className="num" data-label="Dana Cair">
                    {formatMoney(row.payout_amount, row.currency)}
                  </td>
                  <td data-label="Status">
                    {row.status === "reversed" ? (
                      "Dibatalkan"
                    ) : canReverse ? (
                      <ReverseSettlementForm settlementId={row.id} today={today} />
                    ) : (
                      "Tercatat"
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Toko</h2>
        </div>
        {stores.length === 0 ? (
          <p className="dashboard-empty">
            Belum ada toko. Tambahkan toko marketplace Anda di bawah.
          </p>
        ) : (
          <ul className="dashboard-list">
            {stores.map((s) => (
              <li key={s.id} className="dashboard-list-item">
                {storeLabel.get(s.id)}
                {s.pph22_exempt ? " · bebas PPh 22" : ""}
                {s.is_active ? "" : " · tidak aktif"}
              </li>
            ))}
          </ul>
        )}
        {canAddStore ? <MarketplaceStoreForm entity={entity} accounts={accountOptions} /> : null}
      </section>
    </div>
  );
}
