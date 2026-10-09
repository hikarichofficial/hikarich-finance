import { formatMoney } from "@/domain/money/format";
import { calendarDetailText } from "@/domain/tax/calendarDetailText";
import { CALENDAR_STATE_BADGE_TONE, type TaxCalendarRange } from "@/domain/tax/taxCalendarList";
import {
  CALENDAR_STATE_LABELS,
  CALENDAR_STEP_LABELS,
  TAX_TYPE_LABELS,
  taxPeriodLabel,
} from "@/domain/tax/tax";
import type { FinalPreview, TaxCalendarRow } from "@/schemas/tax";
import { TaxEstimateCard } from "./TaxEstimateCard";
import { formatShortDate } from "./format";
import { BackLink } from "@/features/shell/BackLink";

/**
 * Tax Calendar (P13 unbuilt-screens backlog, "Tax Calendar" nav item, Step 09 §15, decision 233): every step
 * (calculate, pay, file, evidence) `tax_calendar` computes for each tax type and period in the requested window,
 * with its own nominal due date and state. Follows the Standard List Screen Pattern with a `from`/`to` date-range
 * toolbar (`CashActivityScreen`'s own shape, decision 203) rather than Tax Ledger's four-select toolbar (decision
 * "3e"), since a calendar is read a window at a time, not filtered by family/source/status the way a ledger feed
 * is. On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; Step 09 §23),
 * with Masa Pajak as the unlabelled leading column, the same convention Tax Ledger uses for Tanggal.
 */
export function TaxCalendarScreen({
  rows,
  range,
  currency,
  entity,
  estimate,
  estimatePeriod,
}: {
  rows: readonly TaxCalendarRow[];
  range: TaxCalendarRange;
  currency: string;
  entity: string | undefined;
  estimate: FinalPreview;
  estimatePeriod: string;
}) {
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Kalender Pajak</h1>
          <p className="list-screen-summary">{rows.length} langkah pada rentang ini.</p>
        </div>
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Dari
            <input type="date" name="from" defaultValue={range.from} />
          </label>
          <label>
            Sampai
            <input type="date" name="to" defaultValue={range.to} />
          </label>
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      <p className="hint">
        <BackLink href={`/tax${entity ? `?entity=${encodeURIComponent(entity)}` : ""}`}>
          ← Kembali ke Ringkasan Pajak
        </BackLink>
      </p>

      <TaxEstimateCard
        estimate={estimate}
        period={estimatePeriod}
        currency={currency}
        entity={entity}
        linkToFinal
      />

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada langkah pajak pada rentang ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Masa Pajak</th>
              <th scope="col">Jenis Pajak</th>
              <th scope="col">Langkah</th>
              <th scope="col">Jatuh Tempo</th>
              <th scope="col">Status</th>
              <th scope="col">Keterangan</th>
              <th scope="col" className="num">
                Kekurangan
              </th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => (
              <tr key={`${row.tax_type}-${row.tax_period}-${row.step}`}>
                <td>{taxPeriodLabel(row.tax_period)}</td>
                <td data-label="Jenis Pajak">{TAX_TYPE_LABELS[row.tax_type]}</td>
                <td data-label="Langkah">{CALENDAR_STEP_LABELS[row.step]}</td>
                <td data-label="Jatuh Tempo">
                  {row.due_date ? formatShortDate(row.due_date) : "—"}
                </td>
                <td data-label="Status">
                  <span className={`status-badge ${CALENDAR_STATE_BADGE_TONE[row.state]}`}>
                    {CALENDAR_STATE_LABELS[row.state]}
                  </span>
                </td>
                <td data-label="Keterangan">
                  {calendarDetailText(row.detail, currency, formatShortDate)}
                </td>
                <td className="num" data-label="Kekurangan">
                  {row.outstanding !== null ? formatMoney(row.outstanding, currency) : "—"}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </div>
  );
}
