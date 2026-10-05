"use client";

import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { useActionState, useState } from "react";
import { formatMoney } from "@/domain/money/format";
import { formatDocumentSize } from "@/domain/documents/documents";
import {
  DIFFERENCE_LABELS,
  EVIDENCE_PURPOSE_LABELS,
  FILING_TAX_TYPES,
  PAYMENT_ISSUE_LABELS,
  TAX_TYPE_LABELS,
  checkTaxPayment,
  taxPeriodLabel,
  type EvidencePurpose,
  type FilingTaxType,
} from "@/domain/tax/tax";
import type { DocumentRow } from "@/schemas/documents";
import type { FinancialAccountPickerRow } from "@/schemas/planning";
import type { TaxEvidenceRow, TaxPaymentRow, TaxPeriodPosition } from "@/schemas/tax";
import {
  linkTaxEvidenceAction,
  reconcileTaxPeriodAction,
  recordTaxFilingAction,
  recordTaxPaymentAction,
  reverseTaxPaymentAction,
} from "./taxFilingActions";
import { idleTaxFilingActionState } from "./taxFilingActionsState";
import { formatShortDate } from "./format";
import { MoneyInput } from "@/features/shared/MoneyInput";

/**
 * Filing & Evidence (P13 unbuilt-screens backlog, "Filing & Evidence" nav item, Step 05 §9, decision 238):
 * the period-closing action set decision 235 deliberately deferred out of `/tax/pph`, `/tax/withholding`
 * and `/tax/ppn` -- recording a payment, recording a filing (original or amendment), reconciling the
 * period, and attaching evidence. One screen serves all three eligible tax types (`FILING_TAX_TYPES`)
 * through its own type selector, rather than three near-identical pages.
 *
 * Evidence attaches to the period's filing or to any confirmed payment (decision 253): each found document
 * carries a "Lampirkan ke" picker (the filing, or a payment by number) and the purpose defaults to the
 * target's natural one (filing receipt / payment proof). The section renders once a filing or a confirmed
 * payment exists; `?doc_q=` drives the document search (a plain GET).
 *
 * Every write action here needs `tax.mark_filed` -- narrower than this page's own `tax.view` gate -- so
 * each form lets its own action's `AuthzError` surface on submit rather than pre-checking the permission,
 * the same shape `taxFinalActions.ts`/`ReverseForm`/`PeriodActions` already use throughout.
 */
export function TaxFilingScreen({
  taxType,
  period,
  position,
  payments,
  currency,
  entityId,
  entity,
  paymentAccounts,
  evidence,
  paymentEvidence = [],
  documentQuery,
  documentResults,
  documentSearchError,
}: {
  taxType: FilingTaxType;
  period: string;
  position: TaxPeriodPosition;
  payments: readonly TaxPaymentRow[];
  currency: string;
  entityId: string;
  entity: string | undefined;
  paymentAccounts: readonly FinancialAccountPickerRow[];
  evidence: readonly TaxEvidenceRow[];
  paymentEvidence?: ReadonlyArray<{
    paymentId: string;
    paymentNumber: string;
    rows: readonly TaxEvidenceRow[];
  }>;
  documentQuery: string | undefined;
  documentResults: readonly DocumentRow[] | undefined;
  documentSearchError: string | undefined;
}) {
  return (
    <div className="record-detail">
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pajak</p>
          <h1>Pelaporan &amp; Bukti</h1>
          <p className="record-detail-counterparty">
            {TAX_TYPE_LABELS[taxType]} &middot; Masa Pajak {taxPeriodLabel(period)}
          </p>
        </div>
      </header>

      <form method="get" className="list-search-form">
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}
        <label>
          Jenis Pajak
          <select name="type" defaultValue={taxType}>
            {FILING_TAX_TYPES.map((t) => (
              <option key={t} value={t}>
                {TAX_TYPE_LABELS[t]}
              </option>
            ))}
          </select>
        </label>
        <label>
          Masa Pajak
          <input type="month" name="period" defaultValue={period.slice(0, 7)} />
        </label>
        <button type="submit" className="btn-secondary">
          Terapkan
        </button>
      </form>

      <PositionSummary position={position} currency={currency} />
      <PaymentHistory
        payments={payments}
        currency={currency}
        taxType={taxType}
        period={period}
        entityId={entityId}
        entity={entity}
      />
      <RecordPaymentForm
        taxType={taxType}
        period={period}
        entityId={entityId}
        entity={entity}
        accounts={paymentAccounts}
        outstanding={position.outstanding_payable}
        assetAvailable={position.asset_available}
      />
      <RecordFilingForm
        taxType={taxType}
        period={period}
        entityId={entityId}
        entity={entity}
        alreadyFiled={position.filing_id !== null}
        filedReference={position.filed_reference}
      />
      <ReconcilePeriodForm
        taxType={taxType}
        period={period}
        entityId={entityId}
        entity={entity}
        differenceCount={position.differences.length}
        reconciliation={position.reconciliation}
      />
      <EvidenceSection
        taxType={taxType}
        period={period}
        entity={entity}
        filingId={position.filing_id}
        filedReference={position.filed_reference}
        evidence={evidence}
        paymentEvidence={paymentEvidence}
        documentQuery={documentQuery}
        documentResults={documentResults}
        documentSearchError={documentSearchError}
      />
    </div>
  );
}

function PositionSummary({
  position,
  currency,
}: {
  position: TaxPeriodPosition;
  currency: string;
}) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Posisi Tercatat</h2>
      </div>
      <dl className="record-summary-grid">
        <div>
          <dt>Terutang (Diakui)</dt>
          <dd>{formatMoney(position.accrued_payable, currency)}</dd>
        </div>
        <div>
          <dt>Sudah Dibayar</dt>
          <dd>{formatMoney(position.paid_payable, currency)}</dd>
        </div>
        <div>
          <dt>Sisa Kekurangan</dt>
          <dd>{formatMoney(position.outstanding_payable, currency)}</dd>
        </div>
        {position.tax_type === "vat" ? (
          <div>
            <dt>PPN Masukan Tersedia</dt>
            <dd>{formatMoney(position.asset_available, currency)}</dd>
          </div>
        ) : null}
        <div>
          <dt>Pelaporan</dt>
          <dd>
            {position.filed_reference
              ? `Dilaporkan (${position.filed_reference})`
              : "Belum dilaporkan"}
          </dd>
        </div>
        <div>
          <dt>Rekonsiliasi</dt>
          <dd>
            {position.reconciliation
              ? `${position.reconciliation.outcome === "reconciled" ? "Sudah direkonsiliasi" : "Direkonsiliasi (ada selisih)"}${position.reconciliation.stale ? " -- sudah berubah sejak itu" : ""}`
              : "Belum direkonsiliasi"}
          </dd>
        </div>
        <div>
          <dt>Bukti Terlampir</dt>
          <dd>{position.evidence_count}</dd>
        </div>
        <div>
          <dt>Per Tanggal</dt>
          <dd>{formatShortDate(position.as_of)}</dd>
        </div>
      </dl>
      {position.differences.length > 0 ? (
        <ul className="dashboard-list">
          {position.differences.map((diff, i) => (
            <li key={i} className="dashboard-list-item">
              <p className="dashboard-list-item-title">{DIFFERENCE_LABELS[diff.code]}</p>
              <p className="dashboard-list-item-detail">{diff.text}</p>
              {diff.amount !== null ? (
                <span className="dashboard-list-item-value">
                  {formatMoney(diff.amount, currency)}
                </span>
              ) : null}
            </li>
          ))}
        </ul>
      ) : null}
    </section>
  );
}

function PaymentHistory({
  payments,
  currency,
  taxType,
  period,
  entityId,
  entity,
}: {
  payments: readonly TaxPaymentRow[];
  currency: string;
  taxType: FilingTaxType;
  period: string;
  entityId: string;
  entity: string | undefined;
}) {
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Riwayat Pembayaran</h2>
      </div>
      {payments.length === 0 ? (
        <p className="hint">Belum ada pembayaran untuk masa ini.</p>
      ) : (
        <table className="record-table-stacked">
          <thead>
            <tr>
              <th>No. Pembayaran</th>
              <th>Tanggal</th>
              <th>Pajak Dibayar</th>
              <th>Kompensasi</th>
              <th>Denda</th>
              <th>Tunai</th>
              <th>Status</th>
              <th></th>
            </tr>
          </thead>
          <tbody>
            {payments.map((p) => (
              <tr key={p.payment_id}>
                <td data-label="No. Pembayaran">{p.payment_number}</td>
                <td data-label="Tanggal">{formatShortDate(p.payment_date)}</td>
                <td data-label="Pajak Dibayar">{formatMoney(p.payable_applied, currency)}</td>
                <td data-label="Kompensasi">{formatMoney(p.asset_applied, currency)}</td>
                <td data-label="Denda">{formatMoney(p.penalty_amount, currency)}</td>
                <td data-label="Tunai">{formatMoney(p.cash_amount, currency)}</td>
                <td data-label="Status">
                  <span
                    className={`status-badge ${p.status === "confirmed" ? "status-badge-success" : "status-badge-neutral"}`}
                  >
                    {p.status === "confirmed" ? "Terkonfirmasi" : "Dibalik"}
                  </span>
                </td>
                <td data-label="">
                  {p.status === "confirmed" ? (
                    <ReversePaymentForm
                      paymentId={p.payment_id}
                      taxType={taxType}
                      period={period}
                      entityId={entityId}
                      entity={entity}
                    />
                  ) : null}
                </td>
              </tr>
            ))}
          </tbody>
        </table>
      )}
    </section>
  );
}

function ReversePaymentForm({
  paymentId,
  taxType,
  period,
  entityId,
  entity,
}: {
  paymentId: string;
  taxType: FilingTaxType;
  period: string;
  entityId: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(
    reverseTaxPaymentAction,
    idleTaxFilingActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [open, setOpen] = useState(false);
  const [reason, setReason] = useState("");
  const today = new Date().toISOString().slice(0, 10);

  if (!open) {
    return (
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        Balik
      </button>
    );
  }

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="entity_id" value={entityId} />
      <input type="hidden" name="tax_type" value={taxType} />
      <input type="hidden" name="period" value={period} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      <label>
        Tanggal Pembalikan
        <input type="date" name="date" required defaultValue={today} max={today} />
      </label>
      <label>
        Alasan (minimal 5 karakter)
        <textarea
          name="reason"
          required
          minLength={5}
          maxLength={500}
          value={reason}
          onChange={(event) => setReason(event.target.value)}
        />
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <div className="invoice-action-buttons">
        <button type="submit" className="btn-danger" disabled={pending || reason.trim().length < 5}>
          {pending ? "Membalik…" : "Balik Pembayaran"}
        </button>
        <button
          type="button"
          className="btn-ghost"
          onClick={() => setOpen(false)}
          disabled={pending}
        >
          Batal
        </button>
      </div>
    </form>
  );
}

function RecordPaymentForm({
  taxType,
  period,
  entityId,
  entity,
  accounts,
  outstanding,
  assetAvailable,
}: {
  taxType: FilingTaxType;
  period: string;
  entityId: string;
  entity: string | undefined;
  accounts: readonly FinancialAccountPickerRow[];
  outstanding: string;
  assetAvailable: string;
}) {
  const [state, action, pending] = useActionState(recordTaxPaymentAction, idleTaxFilingActionState);
  const actionForm = usePreservingForm(action, state);
  const today = new Date().toISOString().slice(0, 10);
  const [payable, setPayable] = useState("");
  const [assetOffset, setAssetOffset] = useState("");
  const [penalty, setPenalty] = useState("");
  const [note, setNote] = useState("");
  const [accountId, setAccountId] = useState("");

  const issues = checkTaxPayment({
    payable: payable || "0",
    assetOffset: assetOffset || "0",
    penalty: penalty || "0",
    taxType,
    note,
    hasAccount: accountId !== "",
  });

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Catat Pembayaran</h2>
      </div>
      <p className="hint">
        Sisa kekurangan saat ini: {outstanding}
        {taxType === "vat" ? ` -- PPN Masukan tersedia untuk kompensasi: ${assetAvailable}` : ""}
      </p>
      <form {...actionForm} className="record-form">
        <input type="hidden" name="entity_id" value={entityId} />
        <input type="hidden" name="tax_type" value={taxType} />
        <input type="hidden" name="period" value={period} />
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}

        <label>
          Tanggal Bayar
          <input type="date" name="payment_date" required defaultValue={today} max={today} />
        </label>
        <label>
          Pajak Dibayar
          <MoneyInput
            name="payable"
            required
            placeholder="0"
            value={payable}
            onValueChange={setPayable}
          />
        </label>
        {taxType === "vat" ? (
          <label>
            Kompensasi PPN Masukan (opsional)
            <MoneyInput
              name="asset_offset"
              placeholder="0"
              value={assetOffset}
              onValueChange={setAssetOffset}
            />
          </label>
        ) : null}
        <label>
          Denda (opsional)
          <MoneyInput name="penalty" placeholder="0" value={penalty} onValueChange={setPenalty} />
        </label>
        <label>
          Akun Pembayar
          <select
            name="account_id"
            value={accountId}
            onChange={(event) => setAccountId(event.target.value)}
          >
            <option value="">(tidak perlu -- dikompensasi penuh)</option>
            {accounts.map((a) => (
              <option key={a.id} value={a.id}>
                {a.name} ({a.currency})
              </option>
            ))}
          </select>
        </label>
        <label>
          Referensi (opsional)
          <input type="text" name="reference" maxLength={200} />
        </label>
        <label>
          Catatan{" "}
          {penalty.trim() !== "" && penalty.trim() !== "0" ? "(wajib untuk denda)" : "(opsional)"}
          <textarea
            name="note"
            maxLength={1000}
            value={note}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>

        {issues.length > 0 ? (
          <ul className="dashboard-list">
            {issues.map((issue) => (
              <li key={issue} className="dashboard-list-item-detail">
                {PAYMENT_ISSUE_LABELS[issue]}
              </li>
            ))}
          </ul>
        ) : null}
        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}

        <button type="submit" className="btn-primary" disabled={pending || issues.length > 0}>
          {pending ? "Menyimpan…" : "Catat Pembayaran"}
        </button>
      </form>
    </section>
  );
}

function RecordFilingForm({
  taxType,
  period,
  entityId,
  entity,
  alreadyFiled,
  filedReference,
}: {
  taxType: FilingTaxType;
  period: string;
  entityId: string;
  entity: string | undefined;
  alreadyFiled: boolean;
  filedReference: string | null;
}) {
  const [state, action, pending] = useActionState(recordTaxFilingAction, idleTaxFilingActionState);
  const actionForm = usePreservingForm(action, state);
  const today = new Date().toISOString().slice(0, 10);
  const [note, setNote] = useState("");

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Catat Pelaporan</h2>
      </div>
      {alreadyFiled ? (
        <p className="hint">
          Masa ini sudah dilaporkan ({filedReference}). Mengirim form ini akan dicatat sebagai
          amendemen.
        </p>
      ) : null}
      <form {...actionForm} className="record-form">
        <input type="hidden" name="entity_id" value={entityId} />
        <input type="hidden" name="tax_type" value={taxType} />
        <input type="hidden" name="period" value={period} />
        <input type="hidden" name="amendment" value={alreadyFiled ? "true" : "false"} />
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}

        <label>
          Tanggal Lapor
          <input type="date" name="filed_date" required defaultValue={today} max={today} />
        </label>
        <label>
          No. Tanda Terima (3-200 karakter)
          <input type="text" name="reference" required minLength={3} maxLength={200} />
        </label>
        <label>
          Dasar Pengenaan yang Dilaporkan
          <MoneyInput name="reported_base" required placeholder="0" />
        </label>
        <label>
          Pajak yang Dilaporkan
          <MoneyInput name="reported_tax" required placeholder="0" />
        </label>
        {taxType === "vat" ? (
          <label>
            Kredit PPN yang Dilaporkan (opsional)
            <MoneyInput name="reported_credit" placeholder="0" />
          </label>
        ) : null}
        <label>
          Catatan {alreadyFiled ? "(wajib, minimal 5 karakter -- apa yang berubah)" : "(opsional)"}
          <textarea
            name="note"
            maxLength={1000}
            required={alreadyFiled}
            minLength={alreadyFiled ? 5 : undefined}
            value={note}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>

        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}

        <button
          type="submit"
          className="btn-primary"
          disabled={pending || (alreadyFiled && note.trim().length < 5)}
        >
          {pending ? "Menyimpan…" : alreadyFiled ? "Catat Amendemen" : "Catat Pelaporan"}
        </button>
      </form>
    </section>
  );
}

function ReconcilePeriodForm({
  taxType,
  period,
  entityId,
  entity,
  differenceCount,
  reconciliation,
}: {
  taxType: FilingTaxType;
  period: string;
  entityId: string;
  entity: string | undefined;
  differenceCount: number;
  reconciliation: TaxPeriodPosition["reconciliation"];
}) {
  const [state, action, pending] = useActionState(
    reconcileTaxPeriodAction,
    idleTaxFilingActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [note, setNote] = useState("");
  const needsNote = differenceCount > 0;

  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Rekonsiliasi Periode</h2>
      </div>
      <p className="hint">
        {reconciliation
          ? `Terakhir direkonsiliasi ${formatShortDate(reconciliation.at.slice(0, 10))}${reconciliation.stale ? " -- catatan buku sudah berubah sejak itu" : ""}.`
          : "Periode ini belum pernah direkonsiliasi."}
      </p>
      <form {...actionForm} className="record-form">
        <input type="hidden" name="entity_id" value={entityId} />
        <input type="hidden" name="tax_type" value={taxType} />
        <input type="hidden" name="period" value={period} />
        {entity ? <input type="hidden" name="entity" value={entity} /> : null}

        <label>
          Catatan {needsNote ? "(wajib, minimal 10 karakter -- ada selisih)" : "(opsional)"}
          <textarea
            name="note"
            maxLength={1000}
            required={needsNote}
            minLength={needsNote ? 10 : undefined}
            value={note}
            onChange={(event) => setNote(event.target.value)}
          />
        </label>

        {state.status === "error" ? (
          <p role="alert" className="error">
            {state.message}
          </p>
        ) : null}

        <button
          type="submit"
          className="btn-secondary"
          disabled={pending || (needsNote && note.trim().length < 10)}
        >
          {pending ? "Menyimpan…" : "Rekonsiliasi Sekarang"}
        </button>
      </form>
    </section>
  );
}

function EvidenceSection({
  taxType,
  period,
  entity,
  filingId,
  filedReference,
  evidence,
  paymentEvidence,
  documentQuery,
  documentResults,
  documentSearchError,
}: {
  taxType: FilingTaxType;
  period: string;
  entity: string | undefined;
  filingId: string | null;
  filedReference: string | null;
  evidence: readonly TaxEvidenceRow[];
  paymentEvidence: ReadonlyArray<{
    paymentId: string;
    paymentNumber: string;
    rows: readonly TaxEvidenceRow[];
  }>;
  documentQuery: string | undefined;
  documentResults: readonly DocumentRow[] | undefined;
  documentSearchError: string | undefined;
}) {
  const targets: EvidenceTarget[] = [
    ...(filingId
      ? [{ type: "tax_filing" as const, id: filingId, label: "Pelaporan periode ini" }]
      : []),
    ...paymentEvidence.map((p) => ({
      type: "tax_payment" as const,
      id: p.paymentId,
      label: `Pembayaran ${p.paymentNumber}`,
    })),
  ];
  return (
    <section className="dashboard-section">
      <div className="dashboard-section-header">
        <h2 className="dashboard-section-title">Bukti Pendukung</h2>
      </div>
      {!filingId && paymentEvidence.length === 0 ? (
        <p className="hint">
          Lampirkan bukti setelah pembayaran atau pelaporan periode ini dicatat.
        </p>
      ) : (
        <>
          {filingId ? (
            <EvidenceList
              title={`Pelaporan ${filedReference ? `(${filedReference})` : "periode ini"}`}
              rows={evidence}
            />
          ) : null}
          {paymentEvidence.map((p) => (
            <EvidenceList key={p.paymentId} title={`Pembayaran ${p.paymentNumber}`} rows={p.rows} />
          ))}

          <form method="get" className="list-search-form">
            <input type="hidden" name="type" value={taxType} />
            <input type="hidden" name="period" value={period.slice(0, 7)} />
            {entity ? <input type="hidden" name="entity" value={entity} /> : null}
            <label>
              Cari Dokumen
              <input type="text" name="doc_q" defaultValue={documentQuery ?? ""} maxLength={200} />
            </label>
            <button type="submit" className="btn-secondary">
              Cari
            </button>
          </form>

          {documentSearchError ? (
            <p role="alert" className="error">
              {documentSearchError}
            </p>
          ) : null}

          {documentResults && documentResults.length === 0 ? (
            <p className="hint">Tidak ada dokumen yang cocok.</p>
          ) : null}

          {documentResults && documentResults.length > 0 ? (
            <ul className="dashboard-list">
              {documentResults.map((doc) => (
                <li key={doc.document_id} className="dashboard-list-item">
                  <p className="dashboard-list-item-title">{doc.file_name}</p>
                  <p className="dashboard-list-item-detail">{formatDocumentSize(doc.size_bytes)}</p>
                  <AttachEvidenceForm
                    documentId={doc.document_id}
                    targets={targets}
                    taxType={taxType}
                    period={period}
                    entity={entity}
                  />
                </li>
              ))}
            </ul>
          ) : null}
        </>
      )}
    </section>
  );
}

interface EvidenceTarget {
  type: "tax_filing" | "tax_payment";
  id: string;
  label: string;
}

function EvidenceList({ title, rows }: { title: string; rows: readonly TaxEvidenceRow[] }) {
  return (
    <>
      <p className="hint">Bukti untuk {title}.</p>
      {rows.length === 0 ? (
        <p className="hint">Belum ada bukti terlampir.</p>
      ) : (
        <ul className="dashboard-list">
          {rows.map((e) => (
            <li key={e.link_id} className="dashboard-list-item">
              <p className="dashboard-list-item-title">{e.file_name}</p>
              <p className="dashboard-list-item-detail">
                {EVIDENCE_PURPOSE_LABELS[e.purpose]} &middot; {formatDocumentSize(e.size_bytes)}{" "}
                &middot; {formatShortDate(e.created_at.slice(0, 10))}
              </p>
            </li>
          ))}
        </ul>
      )}
    </>
  );
}

function AttachEvidenceForm({
  documentId,
  targets,
  taxType,
  period,
  entity,
}: {
  documentId: string;
  targets: readonly EvidenceTarget[];
  taxType: FilingTaxType;
  period: string;
  entity: string | undefined;
}) {
  const [state, action, pending] = useActionState(linkTaxEvidenceAction, idleTaxFilingActionState);
  const actionForm = usePreservingForm(action, state);
  const [targetKey, setTargetKey] = useState(0);
  const target = targets[targetKey] ?? targets[0];
  const [purpose, setPurpose] = useState<EvidencePurpose>(
    target?.type === "tax_payment" ? "payment_proof" : "filing_receipt",
  );
  if (!target) return null;

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="document_id" value={documentId} />
      <input type="hidden" name="target_type" value={target.type} />
      <input type="hidden" name="target_id" value={target.id} />
      {targets.length > 1 ? (
        <label>
          Lampirkan ke
          <select
            value={targetKey}
            onChange={(event) => {
              const index = Number(event.target.value);
              setTargetKey(index);
              setPurpose(
                targets[index]?.type === "tax_payment" ? "payment_proof" : "filing_receipt",
              );
            }}
          >
            {targets.map((t, i) => (
              <option key={t.id} value={i}>
                {t.label}
              </option>
            ))}
          </select>
        </label>
      ) : null}
      <input type="hidden" name="tax_type" value={taxType} />
      <input type="hidden" name="period" value={period} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      <label>
        Tujuan
        <select
          name="purpose"
          value={purpose}
          onChange={(event) => setPurpose(event.target.value as EvidencePurpose)}
        >
          {Object.entries(EVIDENCE_PURPOSE_LABELS).map(([value, label]) => (
            <option key={value} value={value}>
              {label}
            </option>
          ))}
        </select>
      </label>
      {state.status === "error" ? (
        <p role="alert" className="error">
          {state.message}
        </p>
      ) : null}
      <button type="submit" className="btn-secondary" disabled={pending}>
        {pending ? "Melampirkan…" : "Lampirkan"}
      </button>
    </form>
  );
}
