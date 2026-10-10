import { notFound } from "next/navigation";
import { can } from "@/domain/authz/access";
import { AuthzError } from "@/domain/authz/errors";
import { resolveTaxYear } from "@/domain/payroll/taxLiabilities";
import { requireAccess } from "@/services/identity/access";
import { getEntityBaseCurrency, getWithholdingCertificates } from "@/services/payroll/payroll";
import { getEntityLetterhead } from "@/services/settings/settings";
import { WithholdingCertificateScreen } from "@/features/payroll/WithholdingCertificateScreen";
import { todayInBusinessZone } from "@/lib/time";

/**
 * Bukti Potong Tahunan for one employee (decision 397). The same compound permission as every payroll screen
 * (decision 180) plus `payroll.tax_view`, which `payroll_withholding_certificate` hard-requires -- so the
 * fetch is gated here rather than letting the RPC's `FORBIDDEN` surface as an error page, exactly as the Tax
 * & Liabilities screen already does for the annual reconciliation.
 *
 * An employee with no figures for the year is a not-found, not an empty sheet: the RPC returns no row for
 * someone who had not joined yet or who left before January.
 */
export default async function WithholdingCertificatePage({
  params,
  searchParams,
}: {
  params: Promise<{ employee: string }>;
  searchParams: Promise<{ entity?: string; year?: string }>;
}) {
  const { employee } = await params;
  const { entity, year } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  const entityId = membership.entity_id;

  const canRead =
    can(access, entityId, "payroll.compensation_view") &&
    (can(access, entityId, "payroll.run") ||
      can(access, entityId, "payroll.approve") ||
      can(access, entityId, "payroll.pay"));
  if (!canRead) throw new AuthzError("FORBIDDEN");
  if (!can(access, entityId, "payroll.tax_view")) throw new AuthzError("FORBIDDEN");

  const taxYear = resolveTaxYear(year);
  const rows = await getWithholdingCertificates({
    entity_id: entityId,
    year: taxYear,
    employee_id: employee,
  }).catch(() => null);
  const row = rows?.[0];
  if (!row) notFound();

  const [currency, issuer] = await Promise.all([
    getEntityBaseCurrency(entityId),
    getEntityLetterhead(entityId),
  ]);

  const qs = new URLSearchParams({ year: String(taxYear) });
  if (entity) qs.set("entity", entity);

  return (
    <WithholdingCertificateScreen
      row={row}
      year={taxYear}
      currency={currency}
      issuer={issuer}
      issuedOn={todayInBusinessZone()}
      backHref={`/payroll/tax?${qs.toString()}`}
    />
  );
}
