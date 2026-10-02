import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import type { ObligationKind, ObligationStatus } from "@/domain/financing/financing";
import {
  OBLIGATION_STATUS_FILTER_OPTIONS,
  obligationKindTitle,
  obligationStatusBadge,
  type ObligationStatusFilterOption,
} from "@/domain/financing/obligationList";
import type { ObligationRow } from "@/schemas/financing";
import { RecordPreviewLink } from "@/features/shell/RecordPreviewLink";
import { formatShortDate } from "./format";

/**
 * Other Receivables / Other Payables (P13 Part 3f, third increment, Step 09 §9, §16: "Other AR/AP uses
 * simplified obligation screens without forcing invoice/bill semantics"). One component serves both nav items
 * (`/assets/other-receivables`, `/assets/other-payables`), each page passing its own fixed `kind` -- the spec's
 * own "simplified" framing is read as two focused screens rather than one combined list with a kind toggle,
 * matching how the Loan Register (decision 175) and Asset Register (decision 174) each stayed single-purpose.
 * `status` is sent server-side to `obligation_list`'s own `p_status` argument; `?q=` is a client-side
 * number/counterparty/purpose search.
 *
 * On a narrow screen the table becomes stacked cards (`record-table-stacked`, `globals.css`; P13 Part 5,
 * fifth increment; Step 09 §23), the same way `InvoicesListScreen` already does (decision 202) -- Nomor as
 * the unlabelled heading link.
 */
export function ObligationRegisterScreen({
  rows,
  kind,
  status,
  query,
  currency,
  entity,
  createHref,
}: {
  rows: readonly ObligationRow[];
  kind: ObligationKind;
  status: ObligationStatus | null;
  query: string;
  currency: string;
  entity: string | undefined;
  /** Set by the page when the person may create one (`loans.manage`). */
  createHref?: string;
}) {
  const title = obligationKindTitle(kind);
  return (
    <div className="list-screen">
      <header className="list-screen-header">
        <div>
          <h1>Daftar {title}</h1>
          <p className="list-screen-summary">{rows.length} pos ditampilkan.</p>
        </div>
        {createHref ? (
          <Link href={createHref} className="btn-primary">
            Tambah {title}
          </Link>
        ) : null}
      </header>

      <div className="list-screen-toolbar">
        <form method="get" className="list-search-form">
          {entity ? <input type="hidden" name="entity" value={entity} /> : null}
          <label>
            Status
            <select name="status" defaultValue={status ?? ""}>
              {OBLIGATION_STATUS_FILTER_OPTIONS.map((option: ObligationStatusFilterOption) => (
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
            aria-label={`Cari ${title.toLowerCase()}`}
          />
          <button type="submit" className="btn-secondary">
            Terapkan
          </button>
        </form>
      </div>

      {rows.length === 0 ? (
        <div className="list-empty">
          <p>Tidak ada {title.toLowerCase()} pada saringan ini.</p>
        </div>
      ) : (
        <table className="record-table record-table-stacked">
          <thead>
            <tr>
              <th scope="col">Nomor</th>
              <th scope="col">Pihak</th>
              <th scope="col">Tujuan</th>
              <th scope="col">Jatuh Tempo</th>
              <th scope="col" className="num">
                Pokok
              </th>
              <th scope="col" className="num">
                Outstanding
              </th>
              <th scope="col">Status</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((row) => {
              const statusBadge = obligationStatusBadge(row.status, row.overdue);
              const href = entity
                ? `/assets/obligations/${row.obligation_id}?entity=${encodeURIComponent(entity)}`
                : `/assets/obligations/${row.obligation_id}`;
              return (
                <tr key={row.obligation_id}>
                  <td>
                    <RecordPreviewLink
                      href={href}
                      label={row.obligation_number}
                      eyebrow={title}
                      title={row.obligation_number}
                      badges={[{ tone: statusBadge.tone, text: statusBadge.text }]}
                      fields={[
                        { label: "Pihak", value: row.counterparty_name },
                        { label: "Tujuan", value: row.purpose },
                        {
                          label: "Jatuh Tempo",
                          value: row.due_date ? formatShortDate(row.due_date) : "—",
                        },
                        { label: "Pokok", value: formatMoney(row.principal, currency) },
                        { label: "Outstanding", value: formatMoney(row.outstanding, currency) },
                      ]}
                    />
                  </td>
                  <td data-label="Pihak">{row.counterparty_name}</td>
                  <td data-label="Tujuan">{row.purpose}</td>
                  <td data-label="Jatuh Tempo">
                    {row.due_date ? formatShortDate(row.due_date) : "—"}
                  </td>
                  <td className="num" data-label="Pokok">
                    {formatMoney(row.principal, currency)}
                  </td>
                  <td className="num" data-label="Outstanding">
                    {formatMoney(row.outstanding, currency)}
                  </td>
                  <td data-label="Status">
                    <span className={`status-badge status-badge-${statusBadge.tone}`}>
                      {statusBadge.text}
                    </span>
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
