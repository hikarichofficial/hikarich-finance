import Link from "next/link";
import { decodeProblems } from "@/domain/forms/problemTargets";
import { notFound } from "next/navigation";
import { requirePermission } from "@/services/identity/access";
import { getMoneyControl } from "@/services/money/money";
import { listContacts, listNonResidentContactIds } from "@/services/contacts/contacts";
import { getWithholdingAgent } from "@/services/tax/tax";
import { listActiveCategories } from "@/services/accounting/categories";
import { listLineSuggestions } from "@/services/accounting/lineSuggestions";
import { listPayeeNameSuggestions } from "@/services/purchases/expenses";
import { getExpenseDraftForEdit } from "@/services/purchases/purchases";
import { listContactsByRole } from "@/domain/contacts/contactsList";
import { ExpenseForm } from "@/features/purchases/ExpenseForm";
import { todayInBusinessZone } from "@/lib/time";

/** Edit a DRAFT expense (Step 09 §12), gated `bills.edit` -- the permission `update_expense_draft` checks.
 * Anything that is no longer a draft is "not found" here: a confirmed expense is corrected instead. */
export default async function EditExpensePage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string; problems?: string }>;
}) {
  const { id } = await params;
  const { entity, problems } = await searchParams;
  const { membership } = await requirePermission("bills.edit", { entityCode: entity });
  const draft = await getExpenseDraftForEdit(id);
  if (!draft || draft.entity_id !== membership.entity_id) notFound();
  const [accounts, contacts, categories, suggestions, payeeSuggestions, whtAgent, foreignPayeeIds] =
    await Promise.all([
      getMoneyControl(membership.entity_id),
      listContacts(membership.entity_id),
      listActiveCategories(membership.entity_id),
      listLineSuggestions(membership.entity_id, "expense"),
      listPayeeNameSuggestions(membership.entity_id),
      getWithholdingAgent(membership.entity_id),
      listNonResidentContactIds(membership.entity_id),
    ]);
  const vendors = listContactsByRole(contacts, "vendor").filter(
    (c) => c.status === "active" || c.id === draft.payee_id,
  );
  const backHref = entity
    ? `/purchases/expenses/${id}?entity=${encodeURIComponent(entity)}`
    : `/purchases/expenses/${id}`;

  return (
    <div className="record-detail">
      <p className="record-detail-back">
        <Link href={backHref}>← Kembali ke pengeluaran</Link>
      </p>
      <header className="record-detail-header">
        <div>
          <p className="record-detail-eyebrow">Pengeluaran</p>
          <h1>Ubah Draf Pengeluaran</h1>
        </div>
      </header>
      <section className="dashboard-section">
        <ExpenseForm
          accounts={accounts.filter(
            (a) => a.is_active || a.financial_account_id === draft.account_id,
          )}
          vendors={vendors}
          categories={categories}
          whtAgent={whtAgent}
          foreignPayeeIds={foreignPayeeIds}
          suggestions={suggestions}
          payeeSuggestions={payeeSuggestions}
          entity={entity}
          today={todayInBusinessZone()}
          initial={draft}
          initialProblems={decodeProblems(problems)}
        />
      </section>
    </div>
  );
}
