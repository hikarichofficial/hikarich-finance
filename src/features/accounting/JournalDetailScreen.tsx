import Link from "next/link";
import { formatMoney } from "@/domain/money/format";
import {
  entryTypeLabel,
  journalActivityTimeline,
  journalLineTotals,
  journalListStatus,
  journalSourceHref,
  mergeJournalLines,
  type JournalActivityEntry,
} from "@/domain/accounting/journalList";
import type { JournalEntryRow, JournalLineRow, LedgerAccountRow } from "@/schemas/accounting";
import { JournalActions, type JournalActionPermissions } from "./JournalActions";
import { formatShortDate } from "./format";

/**
 * Journal Detail (P13 Part 3d, Step 09 §10, §14). Step 09 §14 only names the Journal List's own requirements
 * (source filtering, period, status, drill-back); it does not spell out a separate field list for the Detail
 * screen the way §12/§13 do for Bills/Transfers. Following the same "Standard Record Detail Pattern subset"
 * reasoning `TransferDetailScreen` used (decision 169) -- here a journal's own debit/credit lines already ARE
 * its accounting detail, so an "Akuntansi" placeholder section would say nothing a Bill/Invoice Detail's
 * placeholder does: Header / Lines / Activity is the whole record, and that is what this screen shows.
 */
export function JournalDetailScreen({
  journal,
  lines,
  accounts,
  reversingJournal,
  baseCurrency,
  permissions,
  entity,
  backHref,
}: {
  journal: JournalEntryRow;
  lines: readonly JournalLineRow[];
  accounts: readonly LedgerAccountRow[];
  reversingJournal: { id: string; journal_number: string | null } | null;
  baseCurrency: string;
  permissions: JournalActionPermissions;
  entity: string | undefined;
  backHref: string;
}) {
  const status = journalListStatus(journal);
  const merged = mergeJournalLines(lines, accounts);
  const totals = journalLineTotals(lines);
  const timeline: JournalActivityEntry[] = journalActivityTimeline(
    journal,
    reversingJournal,
    entity,
  );
  const sourceHref = journalSourceHref(journal.source_type, journal.source_id, entity);

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke daftar jurnal</Link>
      </p>

      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Jurnal · {entryTypeLabel(journal.entry_type)}</p>
          <h1>{journal.journal_number ?? "Draf"}</h1>
          <p className="record-detail-counterparty">{journal.description}</p>
        </div>
        <div className="record-detail-header-end">
          <span className={`status-badge status-badge-${status.tone}`}>{status.text}</span>
          <p className="record-detail-dates">{formatShortDate(journal.entry_date)}</p>
        </div>
      </header>

      <JournalActions
        journalId={journal.id}
        status={journal.status}
        entryType={journal.entry_type}
        entity={entity}
        permissions={permissions}
      />

      {journal.source_type ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Sumber</h2>
          </div>
          <dl className="record-summary-grid">
            <div>
              <dt>Jenis Sumber</dt>
              <dd>{journal.source_type}</dd>
            </div>
            {sourceHref ? (
              <div>
                <dt>Dokumen Sumber</dt>
                <dd>
                  <Link href={sourceHref}>Lihat dokumen sumber →</Link>
                </dd>
              </div>
            ) : null}
            {journal.control_override_reason ? (
              <div>
                <dt>Alasan Override Akun Dilindungi</dt>
                <dd>{journal.control_override_reason}</dd>
              </div>
            ) : null}
          </dl>
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Baris Jurnal</h2>
        </div>
        {merged.length === 0 ? (
          <p className="dashboard-empty">Jurnal ini belum memiliki baris.</p>
        ) : (
          <table className="record-table">
            <thead>
              <tr>
                <th scope="col">Akun</th>
                <th scope="col">Deskripsi</th>
                <th scope="col" className="num">
                  Debit
                </th>
                <th scope="col" className="num">
                  Kredit
                </th>
              </tr>
            </thead>
            <tbody>
              {merged.map(({ line, accountCode, accountName }) => (
                <tr key={line.id}>
                  <td>
                    {accountCode} · {accountName}
                  </td>
                  <td>{line.description ?? "—"}</td>
                  <td className="num">
                    {Number(line.debit) > 0 ? formatMoney(line.debit, baseCurrency) : "—"}
                  </td>
                  <td className="num">
                    {Number(line.credit) > 0 ? formatMoney(line.credit, baseCurrency) : "—"}
                  </td>
                </tr>
              ))}
            </tbody>
            <tfoot>
              <tr>
                <th scope="row" colSpan={2}>
                  Total
                </th>
                <td className="num">{formatMoney(String(totals.debit), baseCurrency)}</td>
                <td className="num">{formatMoney(String(totals.credit), baseCurrency)}</td>
              </tr>
            </tfoot>
          </table>
        )}
      </section>

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Aktivitas</h2>
        </div>
        <ul className="record-activity-list">
          {timeline.map((entry, index) => (
            <li key={`${entry.label}-${index}`} className="record-activity-item">
              {entry.href ? (
                <Link href={entry.href} className={`status-badge status-badge-${entry.tone}`}>
                  {entry.label}
                </Link>
              ) : (
                <span className={`status-badge status-badge-${entry.tone}`}>{entry.label}</span>
              )}
              {entry.date ? (
                <span className="record-activity-date">
                  {formatShortDate(entry.date.slice(0, 10))}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      </section>
    </div>
  );
}
