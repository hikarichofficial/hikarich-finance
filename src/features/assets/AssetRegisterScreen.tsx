import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  ASSET_SOURCE_LABELS,
  ASSET_STATUS_FILTER_OPTIONS,
  assetConditionBadge,
  assetStatusBadge,
  type AssetStatusFilterOption,
} from "@/domain/assets/assetList";
import type { AssetRow } from "@/schemas/assets";
import type { AssetStatus } from "@/domain/assets/assets";
import { formatShortDate } from "./format";

/**
 * Asset Register (P13 Part 3f, first increment, Step 09 §9, §16: "Asset Register supports card/table views,
 * asset detail, acquisition source, depreciation, documents and lifecycle"). Follows the Standard List Screen
 * Pattern with a table view (the spec's own "card/table" choice is left for a later increment -- no other List
 * screen in this codebase has a card view yet either) and a status `<select>` sent straight to `asset_register`'s
 * own `p_status` argument, unlike the Tax Ledger's client-side filters: this RPC already filters server-side.
 * No Create button: an asset is registered from an approved purchase/expense line (Step 08 §5) or loaded at the
 * cut-over, never created directly here.
 */
export function AssetRegisterScreen({
  rows,
  status,
  query,
  currency,
  entity,
}: {
  rows: readonly AssetRow[];
  status: AssetStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Daftar Aset</h1>
          <p className="list-screen-summary">{rows.length} aset ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {ASSET_STATUS_FILTER_OPTIONS.map((option: AssetStatusFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari kode atau nama aset…"
            aria-label="Cari aset"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada aset pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Kode</th>
              <th scope="col">Nama</th>
              <th scope="col">Tanggal Perolehan</th>
              <th scope="col">Sumber</th>
              <th scope="col">Status</th>
              <th scope="col">Kondisi</th>
              <th scope="col" className="num">
                Nilai Buku
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const statusBadge = assetStatusBadge(row.status);
              const conditionBadge = assetConditionBadge(row.condition);
              const href = entity
                ? `/assets/${row.asset_id}?entity=${encodeURIComponent(entity)}`
                : `/assets/${row.asset_id}`;
              return (
                <tr key={row.asset_id}>
                  <td>
                    <Link href={href}>{row.asset_code}</Link>
                  </td>
                  <td>{row.name}</td>
                  <td>{formatShortDate(row.acquisition_date)}</td>
                  <td>{ASSET_SOURCE_LABELS[row.source_type]}</td>
                  <td>
                    <span className={`status-badge status-badge-${statusBadge.tone}`}>
                      {statusBadge.text}
                    </span>
                  </td>
                  <td>
                    <span className={`status-badge status-badge-${conditionBadge.tone}`}>
                      {conditionBadge.text}
                    </span>
                  </td>
                  <td className="num">{formatMoney(row.net_book_value, currency)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
