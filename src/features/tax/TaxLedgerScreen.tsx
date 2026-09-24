import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  TAX_FAMILY_FILTER_OPTIONS,
  TAX_SOURCE_FILTER_OPTIONS,
  TAX_STATUS_FILTER_OPTIONS,
  taxDeterminationHref,
  taxKindLabel,
  taxLedgerStatus,
  type TaxFamilyFilterOption,
  type TaxSourceFilter,
} from "@/domain/tax/taxLedgerList";
import { taxPeriodLabel } from "@/domain/tax/tax";
import type { TaxLedgerRow } from "@/schemas/tax";
import type { TaxType } from "@/domain/tax/tax";
import { formatShortDate } from "./format";

/**
 * Tax Ledger (P13 Part 3e, Step 09 §15): "filterable by tax family, period, source, status and Entity".
 * Follows the Standard List Screen Pattern with a toolbar of four `<select>` filters in one GET form, the same
 * shape the Journal List (decision 172) and Cash/Bank Activity used for a filter set too varied for a small
 * fixed row of tabs. `listTaxLedger` is fetched once per page load (a generous limit, no server-side filter)
 * and every filter here -- family, source, status, period, and the free-text search -- is applied client-side
 * over that one list, mirroring `filterJournalRows`'s own precedent rather than mixing server and client
 * filtering for a page this size.
 */
export function TaxLedgerScreen({
  rows,
  periodOptions,
  taxType,
  sourceType,
  status,
  period,
  query,
  currency,
  entity,
}: {
  rows: readonly TaxLedgerRow[];
  periodOptions: readonly { value: string; label: string }[];
  taxType: TaxType | null;
  sourceType: TaxSourceFilter | null;
  status: string | null;
  period: string | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Buku Besar Pajak</h1>
          <p className="list-screen-summary">{rows.length} entri ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Jenis Pajak
            <select name="type" defaultValue={taxType ?? ""}>
              {TAX_FAMILY_FILTER_OPTIONS.map((option: TaxFamilyFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Sumber
            <select name="source" defaultValue={sourceType ?? ""}>
              {TAX_SOURCE_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {TAX_STATUS_FILTER_OPTIONS.map((option) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Masa Pajak
            <select name="period" defaultValue={period ?? ""}>
              <option value="">Semua Masa</option>
              {periodOptions.map((option) => (
                <option key={option.value} value={option.value}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <input
            type="search"
            name="q"
            defaultValue={query}
            placeholder="Cari deskripsi…"
            aria-label="Cari entri pajak"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada entri pajak pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Tanggal</th>
              <th scope="col">Masa Pajak</th>
              <th scope="col">Jenis</th>
              <th scope="col">Deskripsi</th>
              <th scope="col">Status</th>
              <th scope="col" className="num">
                Jumlah
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const rowStatus = taxLedgerStatus(row.determination_status);
              const href = taxDeterminationHref(row.source_type, row.source_id, entity);
              return (
                <tr key={row.entry_id}>
                  <td>{formatShortDate(row.entry_date)}</td>
                  <td>{taxPeriodLabel(row.tax_period)}</td>
                  <td>{taxKindLabel(row.tax_kind)}</td>
                  <td>
                    {href ? (
                      <Link href={href}>{row.description ?? "—"}</Link>
                    ) : (
                      (row.description ?? "—")
                    )}
                  </td>
                  <td>
                    <span className={`status-badge status-badge-${rowStatus.tone}`}>
                      {rowStatus.text}
                    </span>
                  </td>
                  <td className="num">{formatMoney(row.amount, currency)}</td>
                </tr>
              );
            })}
          </tbody>
        </table>
      )}
    </div>
  );
}
