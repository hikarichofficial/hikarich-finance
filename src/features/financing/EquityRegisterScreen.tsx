import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  EQUITY_KIND_LABELS,
  type EquityKind,
  type EquityStatus,
} from "@/domain/financing/financing";
import {
  EQUITY_KIND_FILTER_OPTIONS,
  EQUITY_STATUS_FILTER_OPTIONS,
  equityRetainedEarningsBadge,
  equityStatusBadge,
  type EquityKindFilterOption,
  type EquityStatusFilterOption,
} from "@/domain/financing/equityList";
import type { EquityRow } from "@/schemas/financing";
import { formatShortDate } from "./format";

/**
 * Capital & Equity (P13 Part 3f, fourth increment, Step 09 §9, §16: "Capital & Equity screen clearly separates
 * contribution, return, dividend/distribution and history"). `kind` and `status` are both sent straight to
 * `equity_list`'s own `p_kind`/`p_status` arguments (server-side filtering, matching the Loan Register's
 * direction+status split, decision 175); `?q=` is a client-side number/counterparty/purpose search. The "clearly
 * separates" requirement is read as a kind filter plus each kind's own label -- one screen, not a route split
 * like Other Receivables/Payables (decision 176), since the spec names this as one screen unlike its own
 * separate "Other AR/AP" bullet.
 */
export function EquityRegisterScreen({
  rows,
  kind,
  status,
  query,
  currency,
  entity,
}: {
  rows: readonly EquityRow[];
  kind: EquityKind | null;
  status: EquityStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Modal & Ekuitas</h1>
          <p className="list-screen-summary">{rows.length} peristiwa ditampilkan.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Jenis
            <select name="kind" defaultValue={kind ?? ""}>
              {EQUITY_KIND_FILTER_OPTIONS.map((option: EquityKindFilterOption) => (
                <option key={option.label} value={option.value ?? ""}>
                  {option.label}
                </option>
              ))}
            </select>
          </label>
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {EQUITY_STATUS_FILTER_OPTIONS.map((option: EquityStatusFilterOption) => (
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
            placeholder="Cari nomor, pihak atau tujuan…"
            aria-label="Cari peristiwa ekuitas"
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada peristiwa ekuitas pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Jenis</th>
              <th scope="col">Tanggal</th>
              <th scope="col">Pihak</th>
              <th scope="col" className="num">
                Jumlah
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const statusBadge = equityStatusBadge(row.status);
              const retainedBadge = equityRetainedEarningsBadge(row.exceeds_retained_earnings);
              const href = entity
                ? `/assets/equity/${row.event_id}?entity=${encodeURIComponent(entity)}`
                : `/assets/equity/${row.event_id}`;
              return (
                <tr key={row.event_id}>
                  <td>
                    <Link href={href}>{row.event_number}</Link>
                  </td>
                  <td>{EQUITY_KIND_LABELS[row.kind]}</td>
                  <td>{formatShortDate(row.event_date)}</td>
                  <td>{row.counterparty_name}</td>
                  <td className="num">{formatMoney(row.amount, currency)}</td>
                  <td>
                    <span className={`status-badge status-badge-${statusBadge.tone}`}>
                      {statusBadge.text}
                    </span>
                    {retainedBadge ? (
                      <span className={`status-badge status-badge-${retainedBadge.tone}`}>
                        {retainedBadge.text}
                      </span>
                    ) : null}
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
