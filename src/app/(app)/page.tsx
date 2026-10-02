import { can } from "@/domain/authz/access";
import { requireAccess } from "@/services/identity/access";
import { autoPostDepreciation } from "@/services/assets/assets";
import { getDashboardSnapshot } from "@/services/dashboard/dashboard";
import { DashboardScreen } from "@/features/dashboard/DashboardScreen";
import { nextMonth, previousMonth } from "@/features/dashboard/format";

/**
 * The Dashboard / Overview screen (P13 Part 2, Step 09 §8, Step 10 §10-13). `?month=YYYY-MM` selects the
 * period (Hero's period selector); an absent or malformed value resolves to the current calendar month
 * (`resolveDashboardPeriod`'s own fallback). `?entity=` keeps selecting the active Entity exactly as P13
 * Part 1's placeholder already did -- the month links below preserve it across period navigation.
 */
export default async function DashboardPage({
  searchParams,
}: {
  searchParams: Promise<{ entity?: string; month?: string }>;
}) {
  const { entity, month } = await searchParams;
  const { access, membership } = await requireAccess({ entityCode: entity });
  // Month-end depreciation posts itself the first time someone who may post it opens the app (decision 269).
  if (can(access, membership.entity_id, "assets.manage")) {
    await autoPostDepreciation(membership.entity_id);
  }
  const snapshot = await getDashboardSnapshot(membership.entity_id, access, { month });

  const entityQuery = entity ? `entity=${encodeURIComponent(entity)}&` : "";
  const monthHref = {
    prev: `/?${entityQuery}month=${previousMonth(snapshot.period.month)}`,
    next: `/?${entityQuery}month=${nextMonth(snapshot.period.month)}`,
  };

  return (
    <DashboardScreen
      snapshot={snapshot}
      displayName={access.display_name}
      entityName={membership.entity_name}
      monthHref={monthHref}
    />
  );
}
