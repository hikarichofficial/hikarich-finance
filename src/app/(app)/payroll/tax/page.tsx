import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { resolveAsOfDate, resolveTaxYear } from "@/domain/payroll/taxLiabilities";
import { requireAccess } from "@/services/identity/access";
import {
  getAnnualReconciliation,
  getEmployeeTaxLedger,
  getEntityBaseCurrency,
  getPayrollLiabilities,
} from "@/services/payroll/payroll";
import { PayrollTaxScreen } from "@/features/payroll/PayrollTaxScreen";

/**
 * Payroll Tax & Liabilities (P13 Part 3g, fourth increment, Step 09 §17). `payroll_liability_report` needs
 * only the same base compound rule as Payroll Runs/Payslips (`payroll.compensation_view` AND at least one of
 * `payroll.run`/`payroll.approve`/`payroll.pay`, decision 180); `payroll_annual_reconciliation`/
 * `payroll_employee_tax_ledger` additionally hard-require `payroll.tax_view` (a real `FORBIDDEN`, not a
 * row/column mask), so those two are fetched only when `can(access, entityId, "payroll.tax_view")`.
 */
export default async function PayrollTaxPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; as_of?: string; year?: string }>;
}) {
  const { entity, as_of, year } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;

  const canRead =
    can(access, entityId, "payroll.compensation_view") &&
    (can(access, entityId, "payroll.run") ||
      can(access, entityId, "payroll.approve") ||
      can(access, entityId, "payroll.pay"));
  if (!canRead) throw new AuthzError("FORBIDDEN");

  const canViewTax = can(access, entityId, "payroll.tax_view");
  const asOf = resolveAsOfDate(as_of);
  const taxYear = resolveTaxYear(year);

  const [liabilities, reconciliation, taxLedger, currency] = await Promise.all([
    getPayrollLiabilities({ entity_id: entityId, as_of: asOf }),
    canViewTax
      ? getAnnualReconciliation({ entity_id: entityId, year: taxYear })
      : Promise.resolve(null),
    canViewTax
      ? getEmployeeTaxLedger({ entity_id: entityId, year: taxYear })
      : Promise.resolve(null),
    getEntityBaseCurrency(entityId),
  ]);

  return (
    <PayrollTaxScreen
      liabilities={liabilities}
      reconciliation={reconciliation}
      taxLedger={taxLedger}
      asOf={asOf}
      year={taxYear}
      currency={currency}
      entity={entity}
      canViewTax={canViewTax}
    />
  );
}
