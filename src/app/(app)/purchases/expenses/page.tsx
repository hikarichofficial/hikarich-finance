import { can } from "@/domain/authz/access";
import { requirePermission } from "@/services/identity/access";
import { listExpenses } from "@/services/purchases/expenses";
import { listContacts } from "@/services/contacts/contacts";
import { filterExpenses, parseExpenseFilter } from "@/domain/purchases/expenseList";
import { ExpensesListScreen } from "@/features/purchases/ExpensesListScreen";

/** Direct Expenses (Step 09 §3, decision 245). Gated `bills.view`: the `expenses_select` RLS permission. */
export default async function ExpensesListPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; status?: string; q?: string }>;
}) {
  const { entity, status, q } = await searchParams;
  const { access, membership } = await requirePermission("bills.view", { entityCode: entity });
  const activeStatus = parseExpenseFilter(status);
  const query = q ?? "";

  const [rows, contacts] = await Promise.all([
    listExpenses(membership.entity_id),
    listContacts(membership.entity_id),
  ]);
  const vendorNames = new Map(contacts.map((c) => [c.id, c.display_name]));

  return (
    <ExpensesListScreen
      rows={filterExpenses(rows, activeStatus, query, vendorNames)}
      vendorNames={vendorNames}
      activeStatus={activeStatus}
      query={query}
      entity={entity}
      canCreate={can(access, membership.entity_id, "bills.create")}
    />
  );
}
