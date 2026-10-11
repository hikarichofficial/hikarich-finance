import { can } from "@/domain/authz/access";
import { requireAccess } from "@/services/identity/access";
import { autoPostDepreciation } from "@/services/assets/assets";
import { getDashboardSnapshot } from "@/services/dashboard/dashboard";
import { DashboardScreen } from "@/features/dashboard/DashboardScreen";
import { nextMonth, previousMonth } from "@/features/dashboard/format";
import { periodYear, resolveDashboardScope } from "@/domain/dashboard/dashboard";

/**
 * The Dashboard / Overview screen (P13 Part 2, Step 09 §8, Step 10 §10-13). `?scope=` chooses what is
 * being summarised -- a month, a year, or everything ever recorded (OWNER, 11 October 2026; decision 404)
 * -- and `?month=` names which one: "YYYY-MM" for a month, "YYYY" for a year, ignored for "all". An absent
 * or malformed value resolves to the current calendar month, the view the Dashboard has always opened in.
 * `?entity=` keeps selecting the active Entity exactly as P13 Part 1's placeholder already did -- the links
 * below preserve both it and the scope across navigation.
 */
export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; month?: string; scope?: string }>;
}) {
  const { entity, month, scope: scopeParam } = await searchParams;
  const scope = resolveDashboardScope(scopeParam);
  const { access, membership } = await requireAccess({ entityCode: entity });
  // Month-end depreciation posts itself the first time someone who may post it opens the app (decision 269).
  if (can(access, membership.entity_id, "assets.manage")) {
    await autoPostDepreciation(membership.entity_id);
  }
  const snapshot = await getDashboardSnapshot(membership.entity_id, access, { month, scope });

  const entityQuery = entity ? `entity=${encodeURIComponent(entity)}&` : "";
  // "All" has nothing before or after it, so its arrows are absent rather than dead.
  const year = periodYear(snapshot.period);
  const periodHref =
    scope === "all"
      ? null
      : scope === "year"
        ? {
            prev: `/?${entityQuery}scope=year&month=${year - 1}`,
            next: `/?${entityQuery}scope=year&month=${year + 1}`,
          }
        : {
            prev: `/?${entityQuery}month=${previousMonth(snapshot.period.month)}`,
            next: `/?${entityQuery}month=${nextMonth(snapshot.period.month)}`,
          };
  const scopeHref = {
    month: `/?${entityQuery}scope=month`,
    year: `/?${entityQuery}scope=year&month=${year}`,
    all: `/?${entityQuery}scope=all`,
  };

  return (
    <DashboardScreen
      snapshot={snapshot}
      displayName={access.display_name}
      entityName={membership.entity_name}
      periodHref={periodHref}
      scopeHref={scopeHref}
    />
  );
}
