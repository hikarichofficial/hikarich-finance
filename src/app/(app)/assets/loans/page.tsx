import { requirePermission } from "@/services/identity/access";
import { getEntityBaseCurrency, listLoans } from "@/services/financing/financing";
import {
  filterLoanRows,
  parseLoanDirectionFilter,
  parseLoanStatusFilter,
} from "@/domain/financing/loanList";
import { LoanRegisterScreen } from "@/features/financing/LoanRegisterScreen";

/** Loan Register (P13 Part 3f, second increment, Step 09 §9, §16). `?direction=` and `?status=` are sent
 * straight to `loan_list`'s own `p_direction`/`p_status` arguments (server-side filtering, matching the Asset
 * Register's own pattern); `?q=` is a client-side loan-number/counterparty search since no RPC parameter covers
 * it. */
export default async function LoanRegisterPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; direction?: string; status?: string; q?: string }>;
}) {
  const { entity, direction, status, q } = await searchParams;
  const { membership } = await requirePermission("loans.view", { entityCode: entity });
  const loanDirection = parseLoanDirectionFilter(direction) ?? null;
  const loanStatus = parseLoanStatusFilter(status) ?? null;
  const query = q ?? "";

  const [entries, currency] = await Promise.all([
    listLoans({
      entity_id: membership.entity_id,
      direction: loanDirection ?? undefined,
      status: loanStatus ?? undefined,
    }),
    getEntityBaseCurrency(membership.entity_id),
  ]);
  const rows = filterLoanRows(entries, query);

  return (
    <LoanRegisterScreen
      rows={rows}
      direction={loanDirection}
      status={loanStatus}
      query={query}
      currency={currency}
      entity={entity}
    />
  );
}
