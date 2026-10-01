"use client";

import { useActionState } from "react";
import { RuleActionResult } from "./TaxRuleForm";
import { discardRuleAction, idleRuleActionState, publishRuleAction } from "./taxRuleActions";

/** Publish or discard a tax rule draft (decision 249). Publishing needs a recent step-up and a verified
 * source; once published the version is final and applies to documents dated from its effective date. */
export function TaxRuleDraftActions({
  ruleId,
  entity,
  stepUpHref,
  publish,
  discard,
}: {
  ruleId: string;
  entity: string | undefined;
  stepUpHref: string;
  publish: boolean;
  discard: boolean;
}) {
  const [publishState, publishFormAction, publishing] = useActionState(
    publishRuleAction,
    idleRuleActionState,
  );
  const [discardState, discardFormAction, discarding] = useActionState(
    discardRuleAction,
    idleRuleActionState,
  );
  if (!publish && !discard) return null;
  return (
    <div className="record-form">
      {publish ? (
        <form action={publishFormAction}>
          <input type="hidden" name="rule_id" value={ruleId} />
          <input type="hidden" name="entity" value={entity ?? ""} />
          <p className="hint">
            Menerbitkan membuat versi ini berlaku untuk dokumen bertanggal sejak tanggal berlakunya dan
            tidak dapat diubah lagi. Memerlukan verifikasi ulang dan status &quot;Terverifikasi&quot;.
          </p>
          <button type="submit" className="btn-primary" disabled={publishing || discarding}>
            {publishing ? "Menerbitkan…" : "Terbitkan aturan"}
          </button>
          <RuleActionResult state={publishState} stepUpHref={stepUpHref} />
        </form>
      ) : null}
      {discard ? (
        <details>
          <summary>Batalkan draf</summary>
          <form action={discardFormAction} className="record-form">
            <input type="hidden" name="rule_id" value={ruleId} />
            <input type="hidden" name="entity" value={entity ?? ""} />
            <label>
              Alasan (minimal 5 karakter)
              <input name="reason" required minLength={5} maxLength={1000} />
            </label>
            <button type="submit" className="btn-danger" disabled={publishing || discarding}>
              {discarding ? "Membatalkan…" : "Batalkan draf"}
            </button>
            <RuleActionResult state={discardState} stepUpHref={stepUpHref} />
          </form>
        </details>
      ) : null}
    </div>
  );
}
