import Link from "next/link";
import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { formatMoney } from "@/domain/money/format";
import {
  RECON_SESSION_STATUS_LABELS,
  RECON_SESSION_STATUS_TONES,
  WORKSPACE_STATUS_LABELS,
  WORKSPACE_STATUS_TONES,
  reconciliationSessionActions,
} from "@/domain/money/reconciliationSession";
import { requirePermission } from "@/services/identity/access";
import {
  getMoneyControl,
  getReconciliationCandidates,
  getReconciliationSession,
  getReconciliationWorkspace,
} from "@/services/money/money";
import { formatShortDate } from "@/features/money/format";
import {
  AddLinesForm,
  CompleteSessionForm,
  DiscardSessionForm,
  IncludeLineForm,
  LineReasonForm,
  MatchForm,
  ReopenSessionForm,
} from "@/features/money/ReconciliationForms";

/**
 * Reconciliation session workspace (Step 09 §13, decision 251). The session header is a direct read of
 * `reconciliation_sessions` under its `money.view` RLS policy; the lines come from `reconciliation_workspace`
 * and the match candidates of the selected line (`?line=`) from `reconciliation_candidates`. Every action is a
 * P4 RPC gated `money.reconcile`.
 */
export default async function ReconciliationSessionPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string; line?: string }>;
}) {
  const { id } = await params;
  const { entity, line } = await searchParams;
  const { access, membership } = await requirePermission("money.view", { entityCode: entity });
  const session = await getReconciliationSession(id).catch(() => null);
  if (!session || session.entity_id !== membership.entity_id) notFound();

  const [lines, control] = await Promise.all([
    getReconciliationWorkspace(id),
    getMoneyControl(membership.entity_id),
  ]);
  const account = control.find((a) => a.financial_account_id === session.financial_account_id);
  const currency = account?.currency ?? "IDR";
  const actions = reconciliationSessionActions(
    session.status,
    can(access, membership.entity_id, "money.reconcile"),
  );
  const selected = actions.work ? lines.find((l) => l.line_id === line) : undefined;
  const candidates =
    selected && selected.display_status !== "matched" && selected.display_status !== "excluded"
      ? await getReconciliationCandidates(selected.line_id)
      : [];

  const qs = entity ? `entity=${encodeURIComponent(entity)}` : "";
  const here = (lineId?: string) => {
    const p = new URLSearchParams(qs);
    if (lineId) p.set("line", lineId);
    const s = p.toString();
    return `/money/reconciliation/${id}${s ? `?${s}` : ""}`;
  };
  const backHref = `/money/reconciliation${qs ? `?${qs}` : ""}`;
  const unresolved = lines.filter(
    (l) => l.display_status === "unmatched" || l.display_status === "possible_match",
  ).length;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke rekonsiliasi</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Kas &amp; Bank · Rekonsiliasi</p>
          <h1>
            {account?.name ?? "Akun"} · {formatShortDate(session.period_start)} –{" "}
            {formatShortDate(session.period_end)}
          </h1>
        </div>
        <span className={`status-badge status-badge-${RECON_SESSION_STATUS_TONES[session.status]}`}>
          {RECON_SESSION_STATUS_LABELS[session.status]}
        </span>
      </header>

      <section className="dashboard-section">
        <dl className="record-summary-grid">
          <div>
            <dt>Saldo Awal Rekening Koran</dt>
            <dd>{formatMoney(session.statement_opening, currency)}</dd>
          </div>
          <div>
            <dt>Saldo Akhir Rekening Koran</dt>
            <dd>{formatMoney(session.statement_closing, currency)}</dd>
          </div>
          <div>
            <dt>Baris Mutasi</dt>
            <dd>
              {lines.length} ({unresolved} belum selesai)
            </dd>
          </div>
          {session.status === "reconciled" ? (
            <>
              <div>
                <dt>Saldo Buku (Sistem)</dt>
                <dd>
                  {session.system_book_balance
                    ? formatMoney(session.system_book_balance, currency)
                    : "—"}
                </dd>
              </div>
              <div>
                <dt>Selisih</dt>
                <dd>{session.difference ? formatMoney(session.difference, currency) : "—"}</dd>
              </div>
              <div>
                <dt>Pergerakan Belum Muncul di Bank</dt>
                <dd>{session.outstanding_items ?? 0}</dd>
              </div>
              {session.accepted_difference_reason ? (
                <div>
                  <dt>Alasan Selisih Diterima</dt>
                  <dd>{session.accepted_difference_reason}</dd>
                </div>
              ) : null}
            </>
          ) : null}
          {session.reopen_reason ? (
            <div>
              <dt>Alasan Dibuka Kembali</dt>
              <dd>{session.reopen_reason}</dd>
            </div>
          ) : null}
          {session.note ? (
            <div>
              <dt>Catatan</dt>
              <dd>{session.note}</dd>
            </div>
          ) : null}
        </dl>
      </section>

      {actions.work ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Tambah Mutasi Rekening Koran</h2>
          </div>
          <AddLinesForm sessionId={id} entity={entity} />
        </section>
      ) : null}

      <section className="dashboard-section">
        <div className="dashboard-section-header">
          <h2 className="dashboard-section-title">Mutasi</h2>
        </div>
        {lines.length === 0 ? (
          <p>Belum ada baris mutasi.</p>
        ) : (
          <table className="record-table record-table-stacked">
            <thead>
              <tr>
                <th scope="col">Tanggal</th>
                <th scope="col">Keterangan</th>
                <th scope="col" className="num">
                  Jumlah
                </th>
                <th scope="col">Status</th>
                <th scope="col">Tindakan</th>
              </tr>
            </thead>
            <tbody>
              {lines.map((l) => (
                <tr key={l.line_id}>
                  <td>{formatShortDate(l.line_date)}</td>
                  <td data-label="Keterangan">
                    {l.description ?? "—"}
                    {l.reference ? ` · ${l.reference}` : ""}
                    {l.exclusion_reason ? (
                      <span className="hint"> (dikecualikan: {l.exclusion_reason})</span>
                    ) : null}
                  </td>
                  <td className="num" data-label="Jumlah">
                    {formatMoney(l.amount, currency)}
                  </td>
                  <td data-label="Status">
                    <span
                      className={`status-badge status-badge-${WORKSPACE_STATUS_TONES[l.display_status]}`}
                    >
                      {WORKSPACE_STATUS_LABELS[l.display_status]}
                    </span>
                  </td>
                  <td data-label="Tindakan">
                    {!actions.work ? (
                      "—"
                    ) : l.display_status === "matched" ? (
                      <LineReasonForm sessionId={id} entity={entity} lineId={l.line_id} kind="unmatch" />
                    ) : l.display_status === "excluded" ? (
                      <IncludeLineForm sessionId={id} entity={entity} lineId={l.line_id} />
                    ) : (
                      <>
                        <Link href={here(l.line_id)}>Cocokkan</Link>
                        <LineReasonForm
                          sessionId={id}
                          entity={entity}
                          lineId={l.line_id}
                          kind="exclude"
                        />
                      </>
                    )}
                  </td>
                </tr>
              ))}
            </tbody>
          </table>
        )}
      </section>

      {selected && selected.display_status !== "matched" && selected.display_status !== "excluded" ? (
        <section className="dashboard-section" id="cocokkan">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">
              Cocokkan baris {formatShortDate(selected.line_date)} ·{" "}
              {formatMoney(selected.amount, currency)}
            </h2>
          </div>
          <MatchForm
            sessionId={id}
            entity={entity}
            lineId={selected.line_id}
            candidates={candidates.map((c) => ({
              id: c.movement_id,
              label: `${formatShortDate(c.movement_date)} · ${formatMoney(c.signed_amount, currency)} · ${
                c.description ?? c.source_type
              }${c.day_difference > 0 ? ` (selisih ${c.day_difference} hari)` : ""}`,
            }))}
          />
          <p>
            <Link href={here()}>Tutup</Link>
          </p>
        </section>
      ) : null}

      {actions.complete || actions.discard || actions.reopen ? (
        <section className="dashboard-section">
          <div className="dashboard-section-header">
            <h2 className="dashboard-section-title">Penyelesaian</h2>
          </div>
          {actions.complete ? <CompleteSessionForm sessionId={id} entity={entity} /> : null}
          {actions.reopen ? <ReopenSessionForm sessionId={id} entity={entity} /> : null}
          {actions.discard ? <DiscardSessionForm sessionId={id} entity={entity} /> : null}
        </section>
      ) : null}
    </div>
  );
}
