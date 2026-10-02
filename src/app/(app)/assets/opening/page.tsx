import Link from "next/link";
import { requirePermission } from "@/services/identity/access";
import { listLedgerAccounts } from "@/services/accounting/ledger";
import { getEntityBaseCurrency } from "@/services/assets/assets";
import { OpeningAssetForm } from "@/features/assets/OpeningAssetForm";

const FIXED_ASSET_KEYS = new Set([
  "FIXED_ASSET_EQUIPMENT",
  "FIXED_ASSET_FURNITURE",
  "FIXED_ASSET_OTHER",
  "PERSONAL_FIXED_ASSET",
]);

/** Aset yang Sudah Dimiliki, gated `system.import` -- the permission `asset_load_opening` itself checks.
 * The accounts offered are the ones the database accepts as a fixed-asset cost account
 * (`is_fixed_asset_account`): the built-in fixed-asset accounts and any account added beside them. */
export default async function OpeningAssetPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string }>;
}) {
  const { entity } = await searchParams;
  const { membership } = await requirePermission("system.import", { entityCode: entity });
  const [accounts, currency] = await Promise.all([
    listLedgerAccounts(membership.entity_id),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const equipmentParent =
    accounts.find((a) => a.system_key === "FIXED_ASSET_EQUIPMENT")?.parent_id ?? null;
  const options = accounts
    .filter(
      (a) =>
        a.account_class === "asset" &&
        !a.is_group &&
        a.status === "active" &&
        ((a.system_key !== null && FIXED_ASSET_KEYS.has(a.system_key)) ||
          (a.system_key === null && a.parent_id !== null && a.parent_id === equipmentParent)),
    )
    .map((a) => ({ id: a.id, label: `${a.code} · ${a.name}` }));
  const qs = entity ? `?entity=${encodeURIComponent(entity)}` : "";

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={`/assets${qs}`}>← Kembali ke daftar aset</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Aset</p>
          <h1>Aset yang Sudah Dimiliki</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <p className="hint">
          Untuk peralatan yang sudah dimiliki sebelum memakai aplikasi ini. Pembelian baru cukup
          dicatat lewat Tagihan atau Pengeluaran dengan perlakuan &quot;Aset&quot;; asetnya
          terdaftar otomatis.
        </p>
        <OpeningAssetForm
          entity={entity}
          next={`/assets/opening${qs}`}
          today={new Date().toISOString().slice(0, 10)}
          depreciable={membership.entity_type !== "personal"}
          currency={currency}
          accounts={options}
        />
      </section>
    </div>
  );
}
