import { AuthzError } from "@/domain/authz/errors";
import { eligibleTaxPaymentAccounts, resolveFilingTaxType } from "@/domain/tax/tax";
import { resolveTaxPeriod } from "@/domain/tax/tax";
import { requirePermission } from "@/services/identity/access";
import { listActiveFinancialAccounts } from "@/services/planning/planning";
import { listDocuments } from "@/services/documents/documents";
import {
  getEntityBaseCurrency,
  getTaxPeriodPosition,
  listTaxEvidence,
  listTaxPayments,
} from "@/services/tax/tax";
import { TaxFilingScreen } from "@/features/tax/TaxFilingScreen";

/**
 * Filing & Evidence (P13 unbuilt-screens backlog, "Filing & Evidence" nav item, Step 05 §9, decision 238) --
 * the period-closing action set decision 235 deliberately deferred out of `/tax/pph`, `/tax/withholding` and
 * `/tax/ppn`: recording a payment, recording a filing, reconciling the period, and (for the period's own
 * filing only -- see `TaxFilingScreen`'s own note) attaching evidence. Covers exactly the three tax types
 * `tax_record_payment`/`tax_record_filing`/`tax_reconcile_period` accept (`resolveFilingTaxType`) -- unlike
 * `/tax/withholding`/`/tax/ppn`, this one screen serves all of them through its own `?type=` selector, since
 * splitting the period-closing actions three ways would just repeat the same five forms three times. Gated
 * `tax.view`, matching `tax_period_position`/`tax_list_payments`/`tax_list_evidence`'s own read checks (the
 * Tax nav section's own parent permission); every write RPC here needs the narrower `tax.mark_filed`, left
 * to each server action's own `AuthzError` handling (`taxFilingActions.ts`) rather than gating the page.
 *
 * `?doc_q=` searches the Documents Center for evidence to attach (`list_documents`, needs the separate
 * `documents.view`) -- a viewer with `tax.view` but not `documents.view` still sees the rest of the page;
 * only the search itself reports it cannot run, the same "let the narrower permission fail where it is
 * actually used" shape as everywhere else on this page.
 */
export default async function TaxFilingPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; type?: string; period?: string; doc_q?: string }>;
}) {
  const { entity, type: typeParam, period: periodParam, doc_q: docQuery } = await searchParams;
  const { membership } = await requirePermission("tax.view", { entityCode: entity });
  const taxType = resolveFilingTaxType(typeParam);
  const period = resolveTaxPeriod(periodParam);
  const entityId = membership.entity_id;

  const [position, payments, currency, accounts] = await Promise.all([
    getTaxPeriodPosition({ entity_id: entityId, tax_type: taxType, period }),
    listTaxPayments({ entity_id: entityId, tax_type: taxType, period }),
    getEntityBaseCurrency(entityId),
    listActiveFinancialAccounts(entityId),
  ]);

  const evidence = position.filing_id
    ? await listTaxEvidence({
        entity_id: entityId,
        target_type: "tax_filing",
        target_id: position.filing_id,
      })
    : [];

  let documentResults: Awaited<ReturnType<typeof listDocuments>> | undefined;
  let documentSearchError: string | undefined;
  if (docQuery) {
    try {
      documentResults = await listDocuments({ entity_id: entityId, q: docQuery, limit: 20 });
    } catch (error) {
      documentSearchError =
        error instanceof AuthzError
          ? "Anda tidak memiliki izin untuk mencari dokumen (documents.view)."
          : "Pencarian dokumen gagal.";
    }
  }

  return (
    <TaxFilingScreen
      taxType={taxType}
      period={period}
      position={position}
      payments={payments}
      currency={currency}
      entityId={entityId}
      entity={entity}
      paymentAccounts={eligibleTaxPaymentAccounts(accounts, currency)}
      evidence={evidence}
      documentQuery={docQuery}
      documentResults={documentResults}
      documentSearchError={documentSearchError}
    />
  );
}
