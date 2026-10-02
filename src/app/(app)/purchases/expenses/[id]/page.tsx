import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { getExpense, getExpenseLines } from "@/services/purchases/expenses";
import { getMoneyControl } from "@/services/money/money";
import { listContacts } from "@/services/contacts/contacts";
import { listActiveCategories } from "@/services/accounting/categories";
import { expenseActions, expensePayeeLabel } from "@/domain/purchases/expenseList";
import { ExpenseDetailScreen } from "@/features/purchases/ExpenseDetailScreen";

/** Direct Expense Detail (decision 245), gated `bills.view`. The expense is read for the active Entity
 * only, so another Entity's expense id never renders here. */
export default async function ExpenseDetailPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<{ entity?: string }>;
}) {
  const { id } = await params;
  const { entity } = await searchParams;
  const { access, membership } = await requirePermission("bills.view", { entityCode: entity });
  const entityId = membership.entity_id;

  const expense = await getExpense(entityId, id);
  if (!expense) notFound();

  const [lines, accounts, contacts, categories] = await Promise.all([
    getExpenseLines(expense.id),
    getMoneyControl(entityId),
    listContacts(entityId),
    listActiveCategories(entityId),
  ]);
  const vendorNames = new Map(contacts.map((c) => [c.id, c.display_name]));
  const account = accounts.find((a) => a.financial_account_id === expense.financial_account_id);
  const backHref = entity
    ? `/purchases/expenses?entity=${encodeURIComponent(entity)}`
    : "/purchases/expenses";

  return (
    <ExpenseDetailScreen
      expense={expense}
      lines={lines}
      payeeLabel={expensePayeeLabel(expense, vendorNames)}
      accountName={account ? `${account.name} (${account.currency})` : "—"}
      categoryNames={new Map(categories.map((c) => [c.id, c.name]))}
      actions={expenseActions(expense.status, {
        canEdit: can(access, entityId, "bills.edit"),
        canSubmit: can(access, entityId, "bills.submit"),
        canPay: can(access, entityId, "bills.pay"),
        canVoid: can(access, entityId, "bills.void"),
        canCreate: can(access, entityId, "bills.create"),
      })}
      entity={entity}
      backHref={backHref}
      canEdit={can(access, entityId, "bills.edit")}
    />
  );
}
