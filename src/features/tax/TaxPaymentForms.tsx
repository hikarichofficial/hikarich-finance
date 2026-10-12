"use client";

import { useState } from "react";
import { useActionState } from "@/features/feedback/useActionState";
import { usePreservingForm } from "@/features/shared/usePreservingForm";
import { ATTACHMENT_ACCEPT } from "@/domain/documents/fileSignature";
import {
  EVIDENCE_PURPOSE_LABELS,
  type EvidencePurpose,
  type FilingTaxType,
} from "@/domain/tax/tax";
import { todayInBusinessZone } from "@/lib/time";
import { reverseTaxPaymentAction, uploadTaxEvidenceAction } from "./taxFilingActions";
import { idleTaxFilingActionState } from "./taxFilingActionsState";

/**
 * The two forms that act on one tax payment or filing, shared by the Filing & Evidence screen and the detail
 * page of a payment (decision 414). `backToPayment` (a payment id) sends the person back to that payment's own
 * page after the action instead of to the period list.
 */
export interface EvidenceTarget {
  type: "tax_filing" | "tax_payment";
  id: string;
  label: string;
}

/** Uploads a proof straight onto the payment or the filing (decision 411); the type of proof follows the target. */
export function TaxEvidenceUploadForm({
  targets,
  taxType,
  period,
  entity,
  backToPayment,
}: {
  targets: readonly EvidenceTarget[];
  taxType: FilingTaxType;
  period: string;
  entity: string | undefined;
  backToPayment?: string;
}) {
  const [state, action, pending] = useActionState(
    uploadTaxEvidenceAction,
    idleTaxFilingActionState,
  );
  const actionForm = usePreservingForm(action, state);
  const [targetKey, setTargetKey] = useState(0);
  const target = targets[targetKey] ?? targets[0];
  const [purpose, setPurpose] = useState<EvidencePurpose>(
    target?.type === "tax_payment" ? "payment_proof" : "filing_receipt",
  );
  if (!target) return null;

  return (
    <form {...actionForm} className="record-form">
      <input type="hidden" name="target_type" value={target.type} />
      <input type="hidden" name="target_id" value={target.id} />
      <input type="hidden" name="tax_type" value={taxType} />
      <input type="hidden" name="period" value={period} />
      {entity ? <input type="hidden" name="entity" value={entity} /> : null}
      {backToPayment ? <input type="hidden" name="back_to_payment" value={backToPayment} /> : null}
      {targets.length > 1 ? (
        <label>
          Unggah untuk
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
      <label>
        Berkas bukti (PDF, JPG, PNG atau WebP, maksimal 4 MB)
        <input type="file" name="file" accept={ATTACHMENT_ACCEPT} required />
      </label>
      <label>
        Jenis bukti
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
        {pending ? "Mengunggah…" : "Unggah Bukti"}
      </button>
    </form>
  );
}

/** Reverses a confirmed payment with a counter-journal (never a delete); lives on the payment's own page. */
export function ReversePaymentForm({
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
  const today = todayInBusinessZone();

  if (!open) {
    return (
      <button type="button" className="btn-ghost" onClick={() => setOpen(true)}>
        Balik Pembayaran
      </button>
    );
  }

  return (
    <form {...actionForm} className="invoice-action-form">
      <input type="hidden" name="payment_id" value={paymentId} />
      <input type="hidden" name="entity_id" value={entityId} />
      <input type="hidden" name="tax_type" value={taxType} />
      <input type="hidden" name="period" value={period} />
      <input type="hidden" name="back_to_payment" value={paymentId} />
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
